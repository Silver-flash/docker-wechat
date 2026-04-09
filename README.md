# dockerwechat

把 Linux 版微信塞进 Docker，浏览器开个标签页就能用。中文输入能打字，聊天记录不会丢，扫码登录一次就行。

主要是写给自己用的，顺手开源一下。

## 跑起来

```bash
docker compose up -d --build
```

然后浏览器打开 [http://localhost:6080](http://localhost:6080)，扫码登录，就这样。

不想自己 build？直接拉预构建镜像（amd64 / arm64 都有）：

```bash
docker run -d --name wechat \
  -p 6080:6080 -p 7070:7070 \
  -v $PWD/data/home:/home/wechat \
  --shm-size=256m \
  ghcr.io/silver-flash/Docker-Wechat:latest
```

右下角有个浮动小按钮，写着 `En` 或 `中`，点一下切输入法。中文走的是 ibus + 智能拼音，跟桌面系统体感差不多。

停掉：

```bash
docker compose down
```

想看它在干嘛：

```bash
docker compose logs -f
```

## 数据放哪了

聊天记录、登录态、图片、配置，全都在项目根目录的 `./data/home` 下。Docker 删了重建都没事，想备份直接打包这个文件夹就行。

## 它是怎么搭起来的

```
浏览器 ──► Xpra HTML5 (:6080) ──► Xpra ──► 微信 (CEF)
                                    │
                                    ├── ibus + libpinyin     ← 输入中文
                                    └── type-server (:7070)  ← 剪贴板/切换 API
```

- **Xpra** 比 VNC 顺手很多，HTML5 客户端开箱即用。
- **ibus** 是这套方案里折腾最久的部分。微信是 CEF 应用，对 fcitx5 支持稀烂，最后只能走 ibus 这条路。引擎用 dconf 在启动时预注册，省得你打开还要手动加 pinyin。
- **type-server** 是个非常小的 Python HTTP 服务，提供 `/paste` 和 `/toggle-ime`，让网页那个浮动按钮有事可做。

## Mac (Apple Silicon) 还是 PC

`docker-compose.yml` 默认下载 arm64 的 deb，M 系列 Mac 直接能用。x86 机器把那行换成：

```yaml
WECHAT_URL: https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.deb
```

## 用起来可能踩到的坑

- **首次打开急着点输入框可能没反应**：等几秒，让 ibus daemon 起完。日志里出现 `ibus ready` 就好了。
- **画面糊或者卡**：把 `docker-compose.yml` 里的 `shm_size` 调大点，CEF 渲染挺吃共享内存的。
- **某些快捷键不灵**：键盘事件经过浏览器 → Xpra → X11 → 微信几层转手，少数组合键会被中间某一层吃掉，没什么好办法。

## 这玩意儿能干嘛

- 在不想装微信客户端的工作机上偶尔回个消息
- 远程服务器上挂一个常驻微信
- 折腾着玩

不能干嘛：

- 不要拿来做机器人或者批量操作，会被封号，也不是这项目的目的。
