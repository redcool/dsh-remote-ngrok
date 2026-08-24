# ngrok 目录（本目录不入 git）

- `ngrok.exe`：**首次使用请手动下载**（约 30MB，见外层 README「ngrok 下载」节）：

  ```
  https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip
  ```

  解压后将 `ngrok.exe` 放入本目录。需 v3.39+（winget 的 v3.3.1 读不懂 v3 配置会秒退）。

- `ngrok.log` / `ngrok_err.log`：运行日志，自动生成，勿提交。

- 首次使用还要配置 authtoken：`ngrok config add-authtoken <你的token>`（token 在 https://dashboard.ngrok.com 获取）。