# 私有更新来源的首次安装

后台继续使用原来的两个通知：Admin「更新」只安装私有 Release 的 Admin；Core「查看」只显示私有 Release 的说明。没有新面板，也没有后台触发整站部署的接口。

## 日常使用

- Admin：修改代码、增加版本并发布带 `release.zip` 的正式 Release；后台原按钮下载并安装。私有 Admin 仓库的 Release 工作流负责生成安装包。
- Core：在自己的 Core 仓库发布 Release 说明；后台「查看」读取说明，服务器程序仍须由维护者部署。
- Shiroi：不参与上述按钮操作，原部署工作流及触发条件保持不变。

## 维护者手动安装

`site-deploy.yml` 是首次安装新 Core/Admin 的手动工具，不会被后台按钮调用，不自动跟随分支或最新上游。

1. 在 `deployment/manifest.json` 固定审查过的三个组件提交 SHA 与版本。首次切换仅更新 Core/Admin；安装工作流不构建、不替换、不重启 Shiroi。清单中的前端 SHA 仅记录当前基线。
2. 经生产变更确认后，在 GitHub Actions 手动运行 `Install private update sources`，填写含此清单的部署仓库完整 SHA、唯一任务编号和已通过预检的 `backup_id`。`check_only=true` 只校验清单。
3. 合并前先运行 `Verify private-update rollback backup`，保存运行中容器的实际文件快照、原配置、站点数据目录与 MongoDB 备份，并在隔离 MongoDB 中实际恢复核验。安装时核对备份后没有发生程序或配置变更，再切换、检查健康与内容/设置指纹，执行一次真实旧版回退演练，最后重新安装新版。失败时执行同一回退脚本。
4. 确认 Core 10.1.10、Admin 6.1.6；登录后台检查原通知的请求走 `/api/v2/update/releases`。没有私有 Release 时不会提示上游版本。

安装脚本沿用已经验证的服务器路径、数据挂载和镜像基础。明确设置 `MX_ADMIN_DEPLOY_MANAGED=false`，启用原 Admin 安装接口。

运行时读取凭据保存在 `/root/mx-space/core/data/mx-space/site-deployment/github-token`，权限 600。脚本沿用已有 `GH_PAT`，服务器仅用它读取两个私有仓库的 Release，不发起 Actions；可用专用只读 `MX_UPDATE_GITHUB_TOKEN` 覆盖。需要 Contents: read，无需新增 Actions 写权限。

版本记录 `site-deployment/current.json` 仅表示最近一次手动整套安装，后台按钮更新 Admin 后该记录不会自动刷新。以后手动安装 Core 时必须显式选择要保留的 Admin 版本，不能盲目重用旧清单；否则会回退后台版本。

备份与程序目录：`/root/site-deployments/<任务编号>/`。原 Compose 不覆盖，生成的覆盖文件选择安装镜像和 Admin 更新开关。不要删除当前程序目录；未来手动重建应同时使用相应覆盖文件。数据库备份不会自动恢复，以免覆盖发布期间的新数据。

在合并到 main 前注意：原 Shiroi 工作流有 main push 触发，本 PR 保留它；合并前应确认原工作流的版本检查与当前前端部署一致。本 PR 尚未合并或执行生产安装。

## 回到本次安装前

备份目录为 `/root/site-update-backups/<backup_id>/`。其中包含当前容器快照的离线镜像包、原配置、Admin 文件校验值、MongoDB 与数据目录备份。

常规回退命令：`bash /root/site-update-backups/<backup_id>/rollback.sh`。脚本恢复原 Core/Admin 的实际程序文件、版本、环境变量及私有更新新增的凭据/记录文件，保留数据库中的后续新内容，不重启 Shiroi、MongoDB 或 Redis。必要时从本地离线镜像包恢复镜像。原 Compose 文件若已被人工改动，校验会阻止直接回退，先检查原因。

安装成功的验收包括实际执行这个回退脚本，验证旧 Admin 文件逐个一致，再切回新程序。MongoDB 恢复演练发生在独立临时容器中，不覆盖正式数据。备份只留在服务器，不上传到公开仓库或 Actions artifact。访问统计、日志、容器 ID、运行时间不属于逐字节复原的范围。不要删除这些备份或执行镜像清理，直到明确不再需要恢复。
