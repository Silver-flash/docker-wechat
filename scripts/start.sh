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
# The panel and config processes are still needed for reliable libpinyin
# startup, but the monitor below hides their control windows so they cannot
# cover WeChat.
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

# Background monitor: hide only IBus control/placeholder windows.
# Do not raise, activate, maximize, or move WeChat windows here: WeChat uses
# child windows for image previews, popups, and some input surfaces, and forced
# main-window activation will cover them.
(
while kill -0 \$WECHAT_PID 2>/dev/null; do
    sleep 3
    ensure_ibus_panel

    # Old IBus panel windows may survive briefly after daemon replacement.
    # Hide only panel/control windows that Xpra can expose as a clickable layer.
    for IBUS_WIN in \$(
        (xdotool search --all --name "IBus Panel" 2>/dev/null; \
         xdotool search --all --name "IBus Preferences" 2>/dev/null; \
         xdotool search --all --name "ibus-setup" 2>/dev/null) | sort -u
    ); do
        IBUS_NAME=\$(xdotool getwindowname "\$IBUS_WIN" 2>/dev/null || true)
        if [ "\$IBUS_NAME" = "IBus Panel" ] || [ "\$IBUS_NAME" = "IBus Preferences" ] || [ "\$IBUS_NAME" = "ibus-setup" ]; then
            xdotool windowunmap "\$IBUS_WIN" 2>/dev/null || true
        fi
    done
done
) &

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
