# 私有仓库发布与后台更新

后台首页的“网站更新”面板通过需要站长身份的 Core 接口发起 GitHub Actions，统一部署 Core、Admin 和 Shiroi。源码来自 Jason 的三个私有仓库，GitHub 凭据保存在服务器的数据目录，不返回浏览器。

## 发布一次代码修改

1. 将经过验证的代码推送到自己的私有源码仓库。首次接入的 Core/Admin 位于各自的 `codex/deployment-button` 分支，Shiroi 保持 `6047be87`。
2. 修改本仓库 `main` 分支的 `deployment/manifest.json`：将需要更新的组件改为完整提交 SHA 和对应 `package.json` 版本；其余组件保持原值。Core 和 Admin 需确认接口兼容。发布清单的修改本身不会部署。
3. 登录管理后台，在首页点击“检查更新”，查看三个组件的当前版本和目标版本。
4. 点击“更新网站”，再点击面板内的“确认更新”。后台提交一次部署任务并定期显示状态，可通过“查看部署记录”打开 GitHub Actions 日志。切换服务时可能短暂断线，页面会重新查询。
5. 部署成功后点击“刷新页面”，使浏览器加载新版后台。

同一个版本无需再次部署，按钮会禁用。仓库源码提交不会自动上线；发布清单决定待发布版本。工作流按提交 SHA 构建，不追随上游版本，也不要求先发布 GitHub Release。

## 实现与首次安装

- `GET /api/v2/update/deployment`：读取当前部署记录、目标清单及最近按钮触发任务的状态。
- `POST /api/v2/update/deployment`：提交预览时的 `releaseSha`。Core 再次核对目标未变化，并使用 Redis 防止重复提交。两个接口都使用原有站长鉴权。
- 部署仓库与工作流在 Core 中固定为 `jason22016/shiroi-deploy-action` / `site-deploy.yml` / `main`；浏览器不能指定仓库、工作流、任意命令或 GitHub Token。
- 首次安装由维护者手动运行 `Private site deployment` 工作流，指定含发布清单的部署仓库完整 SHA 和唯一请求编号。首次运行后后台按钮可用。
- 工作流会先使用现有 `GH_PAT` 发起一次只校验清单、不部署的子任务，确认该凭据具备 Actions 触发权限。正式构建产物通过 SSH 直接上传服务器。
- 原 `Build and Deploy` 工作流的自动触发已停用，保留手动入口作为历史参考。旧 `verify-current.yml` 是一次性同版本验证，不是日常更新入口。
- `MX_ADMIN_DEPLOY_MANAGED=true` 防止旧 Admin 下载接口覆盖 Docker 镜像里的配套后台。

## 服务器记录与回退

当前部署记录：`/root/mx-space/core/data/mx-space/site-deployment/current.json`，包含三个组件的版本和提交、运行镜像 ID、部署工作流编号。每次成功部署后原子更新，后续自动校验实际运行镜像，避免覆盖未经记录的手动变更。

GitHub 凭据文件：同目录 `github-token`，权限为 600，只由服务器读取。所需 GitHub 权限包括部署仓库 Contents 读取和 Actions 读写，以及构建时读取三个私有源码仓库。请勿将凭据写进发布清单或前端配置。

每次发布的备份与程序目录位于 `/root/site-deployments/<任务编号>/`，包含 MongoDB 备份、旧前端入口、旧镜像标签、`compose.verify.yml` 和 `compose.rollback.yml`。当前程序仍使用该目录，不可直接删除。

服务器保留原 Compose 主文件，通过本次目录的覆盖文件选择镜像和托管更新模式。未来手工 Compose 重建应同时传入对应覆盖文件；仅使用原主文件可能重新选中上游镜像。

切换后检查失败会尝试回退程序；数据库备份不会自动恢复，以免覆盖发布期间的用户数据。手工回退程序时，也需要恢复 `previous-deployment.json` 到上述 `current.json`；首次安装回退时若没有该文件，应移走首次创建的部署记录，保留备份。

对于网络超时、GitHub 服务器异常等无法确认是否已接受请求的情况，后台保留请求编号并继续查询，以避免重复部署。若显示“状态待确认”，先通过部署记录查明同编号任务是否存在，再由维护者处理；不要连续触发独立任务。

GitHub 官方接口：[触发工作流](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)。
