# docker-wechat

在 Docker 里跑微信，浏览器打开就能用。支持中文输入，聊天记录持久化。

## 快速开始

**方式一：本地构建**

```bash
git clone https://github.com/Silver-flash/docker-wechat.git
cd docker-wechat
docker compose up -d --build
```

**方式二：拉取预构建镜像**（amd64 / arm64 自动匹配）

```bash
mkdir -p data/home
docker run -d --name wechat \
  -p 6080:6080 -p 7070:7070 \
  -v $PWD/data/home:/home/wechat \
  --shm-size=256m \
  --restart unless-stopped \
  ghcr.io/silver-flash/docker-wechat:latest
```

启动后打开 **http://localhost:6080** ，扫码登录即可。

## 中文输入

页面左上角有个浮动按钮，点击可在 `En` / `中` 之间切换。按钮可以拖到不遮挡操作的位置，切到 `中` 后直接打拼音，和桌面系统体验一致。

## 数据持久化

所有微信数据（聊天记录、图片、登录态）保存在 `./data/home` 目录下。重新构建镜像或重启容器都不会丢失数据，备份时打包这个文件夹即可。

> **注意**：`data/` 已在 `.gitignore` 中，不会被提交到仓库。

## 常用操作

```bash
docker compose logs -f     # 查看日志
docker compose down        # 停止
docker compose up -d       # 再次启动（无需重新构建）
```

## 注意事项

- 首次启动后等几秒再点输入框，日志出现 `ibus ready` 表示输入法就绪。
- 画面异常可调大 `docker-compose.yml` 中的 `shm_size`。
- 少数快捷键可能被浏览器拦截，属于远程桌面的固有限制。

## License

[MIT](LICENSE)
