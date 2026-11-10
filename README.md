# trae-onboard

自动占用企业 TRAE 的 Full 席位，并把新账号导入 Magpie。全程断点续跑，可重复执行。

## 安装

```bash
mkdir -p trae_onboard && cd trae_onboard
wget https://raw.githubusercontent.com/Doeca/trae_onboard/main/activate-seats.sh
wget https://raw.githubusercontent.com/Doeca/trae_onboard/main/magpie-login.sh
wget https://raw.githubusercontent.com/Doeca/trae_onboard/main/trae-onboard.sh
```

两个入口脚本共用 `trae-onboard.sh`，三个文件要放在同一目录。

## 用法

只跑一条命令即可，按提示输入管理员邮箱和密码。

```bash
bash activate-seats.sh
```

开通席位。创建 Mail.tm 临时邮箱 → 用管理员账号发出企业邀请 → 从邮件里取邀请码 → 注册激活 → 核对成员列表和 Full 配额，直到席位填满或没有空位。

- 已激活的账号不会重复创建，未完成的记录会按远端状态清理后重来。
- 每次都会先核对配额：待邀请人数超过空闲席位时停止，不会超额。

```bash
bash magpie-login.sh
```

导入 Magpie。读取 `data/accounts.json` 里已激活的账号，逐个登录 TRAE、走本地回调完成 Magpie 授权，并校验目标 UID 已写入 Magpie 账号库。

- 已导入的账号自动跳过，不占本次额度。
- 未安装 Magpie 时会调用官方脚本安装，并安装 TRAE 插件；过程中临时把 `signInLinkOnly` 打开，结束后恢复原值。

## 附录

| 参数 | 作用 | 适用 |
| --- | --- | --- |
| `--count N` | 本次最多处理 N 个账号，默认自动填充可用席位 | 两个命令 |
| `--dry-run` | 只做离线预览，不联网、不写文件 | 两个命令 |
| `--accounts FILE` | 指定账号/断点文件，默认 `data/accounts.json` | 两个命令 |
| `--admin-file FILE` | 从 JSON 文件读管理员凭据（`chmod 600`），免交互输入 | `activate-seats.sh` |
| `--department-id ID` | 新成员所属部门，默认企业根部门 | `activate-seats.sh` |
| `--mail-timeout S` | 等邀请邮件的总时限，默认 300 秒 | `activate-seats.sh` |
| `--poll-interval S` | 邮件轮询间隔，默认 3 秒 | `activate-seats.sh` |
| `--login-timeout S` | 单个账号 Magpie 授权时限，默认 600 秒 | `magpie-login.sh` |
| `--force-login` | 对已导入的账号重新授权 | `magpie-login.sh` |
| `--magpie-auth-file FILE` | 便携版 Magpie 的 `plugin-auth.json` 路径 | `magpie-login.sh` |

依赖：Bash 3.2+、`curl`、`jq` 1.6+、`openssl`。`data/accounts.json` 是明文敏感文件，请自行保管。建议先 `--dry-run`，再 `--count 1` 验证，最后批量跑。
