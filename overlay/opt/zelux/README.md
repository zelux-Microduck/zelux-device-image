这个目录是 ZELUX 的软件运行目录，镜像构建时由 image/build-image.sh 填充。

结构（版本目录 + 软链，升级只切软链、可回滚）：

    /opt/zelux/
      current -> releases/1.0.0       # zeluxd-run 从这里找软件
      releases/1.0.0/software/        # zeluxd / web / skills / run.py / requirements.txt
      releases/0.9.0/                 # 旧版本，回滚用
      venv/                           # pip 依赖，跨版本共用（requirements 变了才重装）
      wheels/                         # 可选：aarch64 离线轮子（pip download 预置）
      VERSION

开发机（install.sh --dev）会把 current 指向 /opt/zelux/dev/software -> 仓库里的 software/，
改一行代码 `sudo systemctl restart zeluxd` 就生效，不用重新打包。

这个占位文件只是为了让 git 记住目录；构建时会被真正的版本目录覆盖。
