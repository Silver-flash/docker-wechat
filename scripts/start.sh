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

# Refresh ibus engine cache so libpinyin is discoverable
ibus write-cache --system 2>/dev/null || ibus write-cache 2>/dev/null || true

# Pre-register engines in dconf BEFORE ibus-daemon starts (it only reads
# preload-engines at startup). dconf-service needs to be installed.
dconf write /desktop/ibus/general/preload-engines "['xkb:us::eng', 'libpinyin']" 2>/dev/null || true
dconf write /desktop/ibus/general/engines-order "['xkb:us::eng', 'libpinyin']" 2>/dev/null || true

# The web button switches engines explicitly, so keep IBus' own hotkeys hidden.
# The panel and config processes are still needed for reliable libpinyin
# startup, but the monitor below moves their windows away so they cannot cover
# WeChat.
dconf write /desktop/ibus/general/hotkey/triggers "@as []" 2>/dev/null || true
dconf write /desktop/ibus/general/hotkey/next-engine "@as []" 2>/dev/null || true
dconf write /desktop/ibus/general/hotkey/previous-engine "@as []" 2>/dev/null || true

# Start ibus-daemon with X11 backend (now it will pick up the preloaded engines)
ibus-daemon -drx --emoji-extension=disable 2>/dev/null &

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

# Background monitor: every 3 s keep WeChat window visible and centered/maximized
(
LAST_MOVE_TARGET=""
LAST_PARK_LOGGED=0
while kill -0 \$WECHAT_PID 2>/dev/null; do
    sleep 3

    # Old IBus panel windows may survive briefly after daemon replacement.
    # Hide only the tiny panel/control windows that Xpra can expose as a
    # clickable layer. Larger ibus-ui windows may be real pinyin candidates.
    for IBUS_WIN in \$(
        (xdotool search --all --name "IBus Panel" 2>/dev/null; \
         xdotool search --all --name "ibus-ui-gtk3" 2>/dev/null; \
         xdotool search --all --name "IBus Preferences" 2>/dev/null; \
         xdotool search --all --name "ibus-setup" 2>/dev/null) | sort -u
    ); do
        IBUS_NAME=\$(xdotool getwindowname "\$IBUS_WIN" 2>/dev/null || true)
        IBUS_GEOM=\$(xdotool getwindowgeometry "\$IBUS_WIN" 2>/dev/null || true)
        IBUS_W=\$(echo "\$IBUS_GEOM" | grep -oP 'Geometry: \K[0-9]+')
        IBUS_H=\$(echo "\$IBUS_GEOM" | grep -oP 'Geometry: [0-9]+x\K[0-9]+')
        if [ "\$IBUS_NAME" = "IBus Panel" ] || [ "\$IBUS_NAME" = "IBus Preferences" ] || [ "\$IBUS_NAME" = "ibus-setup" ]; then
            xdotool windowunmap "\$IBUS_WIN" 2>/dev/null || true
        elif [ "\$IBUS_NAME" = "ibus-ui-gtk3" ] && [ -n "\$IBUS_W" ] && [ -n "\$IBUS_H" ] && [ "\$IBUS_W" -le 32 ] && [ "\$IBUS_H" -le 32 ]; then
            xdotool windowunmap "\$IBUS_WIN" 2>/dev/null || true
        fi
    done

    # Search by PID and prefer the largest real WeChat window. The old tail -1
    # selection could pick transient helper windows and leave the app behind.
    WIN=""
    WIN_AREA=0
    for CANDIDATE in \$(xdotool search --pid \$WECHAT_PID 2>/dev/null); do
        CANDIDATE_GEOM=\$(xdotool getwindowgeometry "\$CANDIDATE" 2>/dev/null)
        CANDIDATE_W=\$(echo "\$CANDIDATE_GEOM" | grep -oP 'Geometry: \K[0-9]+')
        CANDIDATE_H=\$(echo "\$CANDIDATE_GEOM" | grep -oP 'Geometry: [0-9]+x\K[0-9]+')
        [ -z "\$CANDIDATE_W" ] || [ -z "\$CANDIDATE_H" ] && continue
        if [ "\$CANDIDATE_W" -lt 120 ] || [ "\$CANDIDATE_H" -lt 120 ]; then
            continue
        fi
        CANDIDATE_AREA=\$(( CANDIDATE_W * CANDIDATE_H ))
        if [ "\$CANDIDATE_AREA" -gt "\$WIN_AREA" ]; then
            WIN="\$CANDIDATE"
            WIN_AREA="\$CANDIDATE_AREA"
        fi
    done
    [ -z "\$WIN" ] && continue

    # Get current display and window geometry
    read DISP_W DISP_H < <(xdotool getdisplaygeometry 2>/dev/null)
    WIN_GEOM=\$(xdotool getwindowgeometry "\$WIN" 2>/dev/null)
    WIN_X=\$(echo "\$WIN_GEOM" | grep -oP 'Position: \K-?[0-9]+')
    WIN_Y=\$(echo "\$WIN_GEOM" | grep -oP 'Position: -?[0-9]+,\K-?[0-9]+')
    WIN_W=\$(echo "\$WIN_GEOM" | grep -oP 'Geometry: \K[0-9]+')
    WIN_H=\$(echo "\$WIN_GEOM" | grep -oP 'Geometry: [0-9]+x\K[0-9]+')

    [ -z "\$DISP_W" ] || [ -z "\$DISP_H" ] || [ -z "\$WIN_X" ] || [ -z "\$WIN_Y" ] || [ -z "\$WIN_W" ] || [ -z "\$WIN_H" ] && continue

    # Before a browser client connects, Xpra uses a very large placeholder
    # display. Keep WeChat near the origin instead of centering against that
    # placeholder, otherwise persisted window positions can land far outside
    # the eventual browser canvas.
    if [ "\$DISP_W" -ge 5600 ] && [ "\$DISP_H" -ge 2500 ]; then
        if [ "\$WIN_X" -lt 0 ] || [ "\$WIN_Y" -lt 0 ] || [ "\$WIN_X" -gt 800 ] || [ "\$WIN_Y" -gt 600 ]; then
            xdotool windowmove "\$WIN" 100 100 2>/dev/null || true
            if [ "\$LAST_PARK_LOGGED" -eq 0 ]; then
                echo "[MONITOR] Parked window near origin while waiting for browser client" >> /tmp/wechat.log
                LAST_PARK_LOGGED=1
            fi
        fi
        xdotool windowraise "\$WIN" 2>/dev/null || true
        xdotool windowactivate "\$WIN" 2>/dev/null || true
        continue
    fi

    # If window is off-screen or nearly so, center it
    MAX_X=\$(( DISP_W - WIN_W ))
    MAX_Y=\$(( DISP_H - WIN_H ))
    if [ "\$WIN_X" -gt "\$MAX_X" ] || [ "\$WIN_Y" -gt "\$MAX_Y" ] 2>/dev/null; then
        CENTER_X=\$(( (DISP_W - WIN_W) / 2 ))
        CENTER_Y=\$(( (DISP_H - WIN_H) / 2 ))
        xdotool windowmove "\$WIN" "\$CENTER_X" "\$CENTER_Y" 2>/dev/null
        MOVE_TARGET="\${CENTER_X},\${CENTER_Y}"
        if [ "\$MOVE_TARGET" != "\$LAST_MOVE_TARGET" ]; then
            echo "[MONITOR] Moved window to center (\${CENTER_X},\${CENTER_Y})" >> /tmp/wechat.log
            LAST_MOVE_TARGET="\$MOVE_TARGET"
        fi
    fi

    # Try to maximize if the window allows it (main window after login)
    xdotool windowmaximize "\$WIN" 2>/dev/null || true
    xdotool windowraise "\$WIN" 2>/dev/null || true
    xdotool windowactivate "\$WIN" 2>/dev/null || true
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
