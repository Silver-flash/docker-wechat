#!/bin/bash
set -e

WECHAT_BINS=("/opt/wechat/wechat" "/opt/wechat-beta/wechat" "$(command -v wechat 2>/dev/null)")
WECHAT_BIN=""
for bin in "${WECHAT_BINS[@]}"; do
    [ -n "${bin}" ] && [ -x "${bin}" ] && WECHAT_BIN="${bin}" && break
done
[ -z "${WECHAT_BIN}" ] && echo "[ERROR] WeChat not found" && exit 1

# Create XDG_RUNTIME_DIR required by dbus / pulseaudio
mkdir -p /run/user/1000
chmod 700 /run/user/1000
chown wechat:wechat /run/user/1000

# /home/wechat is bind-mounted from the host (./data on the host).
# Fix ownership so the in-container `wechat` user (uid 1000) can read/write.
mkdir -p /home/wechat
chown wechat:wechat /home/wechat
# Only chown top-level entries shallowly to avoid huge recursive chowns on
# every start; deeper trees are owned correctly after first creation.
find /home/wechat -maxdepth 1 -mindepth 1 -not -user wechat -exec chown -R wechat:wechat {} + 2>/dev/null || true

# Prepare log file; tail it so WeChat output appears in docker logs
touch /tmp/wechat.log
chown wechat:wechat /tmp/wechat.log
tail -f /tmp/wechat.log &

patch_xpra_keyboard_bug() {
    local xpra_keyboard="/usr/lib/python3/dist-packages/xpra/x11/server_keyboard_config.py"
    [ -f "${xpra_keyboard}" ] || return 0

    if grep -q "def do_get_keycode_new(self, client_keycode, keyname, pressed, modifiers, group):" "${xpra_keyboard}"; then
        sed -i \
            -e "s/return self.do_get_keycode_new(client_keycode, keyname, pressed, modifiers, group)/return self.do_get_keycode_new(client_keycode, keyname, pressed, modifiers, keystr, group)/" \
            -e "s/def do_get_keycode_new(self, client_keycode, keyname, pressed, modifiers, group):/def do_get_keycode_new(self, client_keycode, keyname, pressed, modifiers, keystr, group):/" \
            "${xpra_keyboard}"
        echo "[INFO] Patched xpra keyboard keystr bug"
    fi
}

cleanup_stale_x_display() {
    mkdir -p /tmp/.X11-unix
    chmod 1777 /tmp/.X11-unix
    chown root:root /tmp/.X11-unix 2>/dev/null || true

    if [ -f /tmp/.X1-lock ] && ! pgrep -f 'X(vfb|org).*:1' >/dev/null 2>&1; then
        rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
        echo "[INFO] Removed stale X display :1 lock"
    fi
}

patch_xpra_keyboard_bug
cleanup_stale_x_display

# Write wrapper to /tmp (NOT /home/wechat — that path is bind-mounted from
# the host and would shadow anything we put there).
WRAPPER=/tmp/run-wechat.sh
cat > "${WRAPPER}" <<EOF
#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/1000

# Start a dbus session bus (required by WeChat/CEF and ibus)
eval \$(dbus-launch --sh-syntax 2>/dev/null) || true

# ─── IBus IME env vars (Chromium/CEF has first-class IBus support) ───
export XMODIFIERS=@im=ibus
export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus
export XDG_CURRENT_DESKTOP=GNOME
export DESKTOP_SESSION=gnome
export GDK_BACKEND=x11
export NO_AT_BRIDGE=1

ensure_ibus_panel() {
    if [ -x /usr/libexec/ibus-ui-gtk3 ] && \
       ! pgrep -u "\$(id -u)" -f '/usr/libexec/ibus-ui-gtk3' >/dev/null 2>&1; then
        /usr/libexec/ibus-ui-gtk3 >> /tmp/wechat.log 2>&1 &
        echo "[WRAPPER] ibus-ui-gtk3 PID=\$!" >> /tmp/wechat.log
    fi
}

# Refresh ibus engine cache so libpinyin is discoverable
ibus write-cache --system 2>/dev/null || ibus write-cache 2>/dev/null || true

# Pre-register engines in dconf BEFORE ibus-daemon starts (it only reads
# preload-engines at startup). dconf-service needs to be installed.
dconf write /desktop/ibus/general/preload-engines "['xkb:us::eng', 'libpinyin']" 2>/dev/null || true
dconf write /desktop/ibus/general/engines-order "['xkb:us::eng', 'libpinyin']" 2>/dev/null || true

# The web button switches engines explicitly, so keep IBus' own hotkeys hidden.
# Keep ibus-ui-gtk3 running so libpinyin can show its candidate panel.
dconf write /desktop/ibus/general/hotkey/triggers "@as []" 2>/dev/null || true
dconf write /desktop/ibus/general/hotkey/next-engine "@as []" 2>/dev/null || true
dconf write /desktop/ibus/general/hotkey/previous-engine "@as []" 2>/dev/null || true

# Start ibus-daemon with X11 backend (now it will pick up the preloaded engines)
ibus-daemon -d -r -x -R --emoji-extension=disable >> /tmp/wechat.log 2>&1 &

# Wait until ibus is responsive
for i in 1 2 3 4 5 6 7 8 9 10; do
    if ibus engine >/dev/null 2>&1; then
        echo "[WRAPPER] ibus ready after \${i}*0.3s" >> /tmp/wechat.log
        break
    fi
    sleep 0.3
done

# Default to English keyboard; the toggle button switches to libpinyin
ibus engine xkb:us::eng 2>/dev/null || true
echo "[WRAPPER] ibus engines: \$(ibus list-engine 2>/dev/null | grep -E 'libpinyin|xkb:us' | tr '\n' ' ')" >> /tmp/wechat.log
ensure_ibus_panel

# Start UTF-8 clipboard injection + IME toggle server
python3 /scripts/type-server.py &

echo "[WRAPPER] Launching: ${WECHAT_BIN}" >> /tmp/wechat.log

# Launch WeChat (Chromium picks up GTK_IM_MODULE=ibus automatically)
${WECHAT_BIN} \\
    --no-sandbox \\
    --password-store=basic \\
    >> /tmp/wechat.log 2>&1 &
WECHAT_PID=\$!
echo "[WRAPPER] WeChat PID=\$WECHAT_PID" >> /tmp/wechat.log

# Brief check: did it crash immediately?
sleep 2
if ! kill -0 \$WECHAT_PID 2>/dev/null; then
    echo "[WRAPPER] WeChat exited immediately!" >> /tmp/wechat.log
    wait \$WECHAT_PID
    echo "[WRAPPER] Exit code: \$?" >> /tmp/wechat.log
    exit 1
fi
echo "[WRAPPER] WeChat still running after 2s — OK" >> /tmp/wechat.log

wait \$WECHAT_PID
echo "[WRAPPER] WeChat ended (exit \$?)" >> /tmp/wechat.log
EOF
chmod +x "${WRAPPER}"
chown wechat:wechat "${WRAPPER}"

echo "[INFO] WeChat : ${WECHAT_BIN}"
echo "[INFO] Browser: http://localhost:6080"

# Note: no 'exec' here so background tail -f above keeps running
su - wechat -c "
    xpra start :1 \
      --bind-ws=0.0.0.0:6080 \
      --html=on \
      --socket-dir=/run/user/1000/xpra \
      --socket-dirs=/run/user/1000/xpra \
      --start-child=${WRAPPER} \
      --exit-with-children=no \
      --no-daemon \
      --xvfb='Xvfb +extension GLX +extension Composite -screen 0 1440x900x24+32 -dpi 96 -nolisten tcp -noreset -auth \$XAUTHORITY' \
      --resize-display=yes \
      --encoding=auto \
      --clipboard=yes \
      --clipboard-direction=both \
      --notifications=no \
      --speaker=disabled \
      --microphone=disabled \
      2>&1
"
