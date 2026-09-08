# 整理与审计说明

当前公开树基于上游 commit `671f2f486ce10825e02ea547e3ce3667062676f0` 整改。构建器在没有
`.git` 的源码快照中读取 `manifest/source-commit.txt` 作为上游基线，同时计算 `sourceTreeSha256`
标识实际参与打包的适配源码；两者不能互相替代。

本目录记录公开能力包的范围、兼容性和部署边界。内容以功能为中心，不包含个人身份、账号配置或一次性运行状态。

## 已纳入

- 50 个带独立元数据和功能说明的 Skill
- 7 个按功能命名的 Agent TOML
- Windows 10/11 优先的安装、打包和验证脚本
- MCP/API 清单、连接字段、无密钥配置模板和环境依赖说明
- 25 个核心默认安装项、完整依赖闭包与 SHA-256 文件清单
- Python 运行时直接输入、传递依赖物化脚本、wheelhouse 状态清单和 Windows per-user 安装契约

## 明确不纳入

- API Key、Token、Cookie、`.env`、私有 URL 和账号配置
- 会话历史、记忆数据库、日志、缓存、草稿和生成产物
- 依赖特定宿主协议的远程画布、设备节点和网关控制
- 未经用户提供和审查的 MCP Server 可执行文件或运行时二进制

## 兼容性原则

每个 Skill 必须在 `manifest/skill-audit.json` 中声明原始状态、整改后状态、依赖对象、启用条件和健康检查。
每个 Agent 必须在 `manifest/agent-audit.json` 中声明必需 Skill、可选 Skill、运行时依赖、连接依赖和降级路径。
无法在当前 Codex 环境确认的能力会标记为 `auto-installable-runtime`、`guided-config` 或 `unsupported`，
不会以“已经可用”的形式进入默认安装集合。
