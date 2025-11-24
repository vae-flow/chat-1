# One-API 本地快速发布版（v0.6.10 Windows 便携版）

已下载官方发布的 `one-api.exe`（存放于当前目录），可直接运行，无需 Go 环境。

## 启动
```powershell
.\one-api.exe --port 3000
```
- 默认使用内置 SQLite 存储，数据会保存在同目录。
- 浏览器打开 `http://localhost:3000`。
- 初始管理员：用户名 `root`，密码 `123456`。首次登录后请立即在「个人设置」修改密码。

## 最小配置流程（用于转发 OpenAI 兼容接口）
1) 登录后台 → 「渠道」→ 新建渠道  
   - 供应商：选 OpenAI（或你要转发的服务商）  
   - Key：填你的真实上游密钥  
   - 基础模型列表：可保留默认或按需调整  
   - 状态：启用
2) 「令牌」→ 新建令牌，选择可用渠道（或使用默认负载均衡），得到类似 `sk-xxxx` 的访问密钥。
3) 可在「模型」中查看/启用模型别名；调用时用别名或真实模型名即可。

## API 调用示例（OpenAI 兼容）
- 端口：`3000`（可在启动参数修改）  
- 模型名：在后台启用的模型或别名，如 `gpt-4o-mini`、`gpt-4o-2024-11-20` 等。  
- 令牌：步骤 2 生成的 `sk-***`。

```bash
curl -X POST http://localhost:3000/v1/chat/completions ^
  -H "Authorization: Bearer sk-your-oneapi-token" ^
  -H "Content-Type: application/json" ^
  -d "{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"system\",\"content\":\"你是学习与生活管理的AI搭子\"},{\"role\":\"user\",\"content\":\"给我一个今天的三件事清单\"}],\"stream\":false}"
```
- 如需流式，把 `"stream":true`，并按 SSE 读取。
- 若要固定使用某个渠道，可用 `Authorization: Bearer sk-token-CHANNEL_ID`。

## 与 AI 搭子模板结合
- 直接将 `ai_partner_template.txt` 内容作为系统提示（system prompt）传给聊天接口，即可获得预设人格。
- 示例（伪代码）：
```json
{
  "model": "gpt-4o-mini",
  "messages": [
    {"role": "system", "content": "<粘贴 ai_partner_template.txt 全文>"},
    {"role": "user", "content": "帮我制定本周学习计划"}
  ]
}
```

## 其他提示
- 若要持久化到外部数据库，可设置环境变量 `SQL_DSN`，格式示例：`user:pass@tcp(host:3306)/one-api`。
- 生产环境建议反代并配置 HTTPS，限制管理口令，定期备份数据文件。

## 本地 Python 客户端（自动拼接人格 + 记忆）
已提供 `app.py`，会把精简版人格提示词与本地记忆文件一起送到 one-api：
1. 安装依赖：`pip install -r requirements.txt`
2. 复制配置：`copy config.example.json config.json`，填写：
   - `api_base`：你的外部 one-api 地址（如 `https://your-oneapi-host/v1`）
   - `api_key`：后台令牌 `sk-...`
   - `model`：填 `auto` 会从 `/models` 拉取列表并让你在终端选择；或直接写启用的模型/别名（如 `gpt-4o-mini`）
3. 运行：`python app.py`，按提示输入你的需求。
   - 自动读取 `ai_partner_template_compact.txt`（约 2.1k 字）作为系统 prompt。
   - 自动加载/写入 `memory.json`，把最近对话摘要和档案一起传给接口。
   - 每次对话后更新记忆，无需手动拼装。
