# 私有更新来源的首次安装

后台继续使用原来的两个通知：Admin「更新」只安装私有 Release 的 Admin；Core「查看」只显示私有 Release 的说明。没有新面板，也没有后台触发整站部署的接口。

## 日常使用

- Admin：修改代码、增加版本并发布带 `release.zip` 的正式 Release；后台原按钮下载并安装。私有 Admin 仓库的 Release 工作流负责生成安装包。
- Core：在自己的 Core 仓库发布 Release 说明；后台「查看」读取说明，服务器程序仍须由维护者部署。
- Shiroi：不参与上述按钮操作，原部署工作流及触发条件保持不变。

## 维护者手动安装

`site-deploy.yml` 是首次安装新 Core/Admin 的手动工具，不会被后台按钮调用，不自动跟随分支或最新上游。

1. 在 `deployment/manifest.json` 固定审查过的三个组件提交 SHA 与版本。首次切换仅更新 Core/Admin，Shiroi 仍为原 `6047be87`。
2. 经生产变更确认后，在 GitHub Actions 手动运行 `Install private update sources`，填写含此清单的部署仓库完整 SHA 和唯一任务编号。`check_only=true` 只校验清单。
3. 构建产物直接传到服务器，先备份，再切换、检查健康与内容指纹；失败时尝试回退程序。
4. 确认 Core 10.1.10、Admin 6.1.6；登录后台检查原通知的请求走 `/api/v2/update/releases`。没有私有 Release 时不会提示上游版本。

安装脚本沿用已经验证的服务器路径、数据挂载和镜像基础。明确设置 `MX_ADMIN_DEPLOY_MANAGED=false`，启用原 Admin 安装接口。

运行时读取凭据保存在 `/root/mx-space/core/data/mx-space/site-deployment/github-token`，权限 600。脚本沿用已有 `GH_PAT`，服务器仅用它读取两个私有仓库的 Release，不发起 Actions；可用专用只读 `MX_UPDATE_GITHUB_TOKEN` 覆盖。需要 Contents: read，无需新增 Actions 写权限。

版本记录 `site-deployment/current.json` 仅表示最近一次手动整套安装，后台按钮更新 Admin 后该记录不会自动刷新。以后手动安装 Core 时必须显式选择要保留的 Admin 版本，不能盲目重用旧清单；否则会回退后台版本。

备份与程序目录：`/root/site-deployments/<任务编号>/`。原 Compose 不覆盖，生成的覆盖文件选择安装镜像和 Admin 更新开关。不要删除当前程序目录；未来手动重建应同时使用相应覆盖文件。数据库备份不会自动恢复，以免覆盖发布期间的新数据。

在合并到 main 前注意：原 Shiroi 工作流有 main push 触发，本 PR 保留它；合并前应确认原工作流的版本检查与当前前端部署一致。本 PR 尚未合并或执行生产安装。
