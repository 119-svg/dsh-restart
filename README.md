# @119-svg/dsh-restart

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 桌面端加一个**一键整机重启**：
点一下 = 完全关闭并重新打开 DSH Desktop，**效果与「从托盘退出、再双击图标打开」完全一致**。
约 8 秒回来，窗口自己出现，不用手动点图标。

> English: [README.en.md](README.en.md)

## 为什么需要它

DSH Desktop 官方外壳**没有给插件留任何「重启应用」的接口**（全量搜过 app.asar：`desktopRuntime` /
`requestRestart` 零命中；能真正 `app.relaunch()` 的只有 Electron 主进程内部两处，且托盘菜单里的
「重启应用与 Host」只在开发构建出现）。生产版用户能做的最接近的事，就是托盘退出 + 手动重开。

而插件想自己干这件事，会撞上一串平台细节——这个插件把它们都处理好了，并且把踩坑过程写在下文。

## 安装

> ⚠️ 装 DSH 插件**必须先完全退出 DSH Desktop（含托盘）**：运行中的主进程会锁住 profile 里已加载的
> 原生包，pnpm 会 `ERR_PNPM_EPERM` 自锁。装完再启动。

```sh
# npm 包
dsh plugin --profile desktop add @119-svg/dsh-restart

# 或从本地目录 / git 源
dsh plugin --profile desktop add /absolute/path/to/dsh-restart
```

启动后，侧边栏底部（设置旁边）会出现 **⏻** 按钮。

## 使用

- 点侧边栏底部 **⏻**，确认 → 约 8 秒后窗口自己回来。
- 只想演练、不真重启（脚本侧 `-DryRun`）：

  ```sh
  curl -X POST http://127.0.0.1:<DSH端口>/api/dsh-restart/restartApp \
       -H 'content-type: application/json' -d '{"dryRun":true}'
  ```

- 状态查询：`POST /api/dsh-restart/status`
- 不装插件也能用：直接双击 `scripts/restart-dsh.cmd`（环境变量 `DSH_RESTART_DRYRUN=1` 可演练）。

## 它是怎么做到的

`scripts/restart-dsh.ps1` 是**同一个文件的三个角色**：

| 角色 | 怎么进 | 干什么 |
|---|---|---|
| phase 1 | 无参数（插件或 .cmd 调用） | 写 `~/.dsh/dsh-restart.pending` 标记 → 用 **WMI** 拉起下面两个 → 立刻退出 |
| worker | `-Detached` | 等 1 秒让按钮响应回到界面 → 试着优雅关窗 → `taskkill /T /F` 杀掉整棵应用树 → 等到进程清空 → 停 0.5 秒 → 按原路径重启 → 轮询验证窗口回来 |
| guard | `-Guard`（默认延时 30 秒） | 哨兵：标记还在、且一个应用进程都没有 ⇒ 判定 worker 半路死了，自己补一次启动 |

**关键点：worker 必须用 WMI 创建**（`Win32_Process.Create`），这样它的父进程是 `WmiPrvSE.exe`，
**脱离 DSH 的受管子进程容器**。否则会看到最气人的那种失败：「应用关掉了，再也没回来」。

### 时间预算（实测）

| 阶段 | 耗时 |
|---|---|
| 响应留时 + 优雅关窗（窗口一消失即停等） | ~1.3s |
| `taskkill` 杀整棵树 | ~1.0s |
| 等单实例锁释放 | 0.5s |
| 应用自己启动到窗口出现 | ~5s（官方外壳的启动耗时，外部改不动） |
| **合计** | **约 8 秒** |

## 四个坑（照抄前先看这段）

1. **宿主里不能用 Node 原生 `child_process.spawn`** —— 会被 DSH 沙箱**同步抛 EPERM**（`stdio` 设 ignore 也一样）。
   唯一通道是 DSH 自带的受管子进程服务：`ctx.get('subprocess')` → `resolveExecutable()` → `spawn({...})`。
2. **`subprocess.spawn` 的 `graceMs` 是必填项**。官方 `validateSubprocessSpec` 会校验它是「正有限数且
   ≤ 2^31-1」，漏传直接抛 `subprocess graceMs must be a positive finite number…`。
3. **DSH 的子进程活在受管容器里，宿主退出时会连坐清理容器成员及其后代**。所以「自己杀自己」的脚本
   活不到重启那一步：日志会停在 `taskkill` 那一行、一条输出都没有，应用关掉、永不回来。
   **必须让干活的进程脱离容器**——本插件用 WMI 创建（备选：计划任务）。
4. **`CloseMainWindow()` 在官方外壳上只是把窗口收进托盘，不会退出进程**。所以别给它固定等待时间：
   发完 WM_CLOSE 后**窗口一消失就立刻停等**，真正结束交给 `taskkill`。（早期版本在这里白等 6 秒。）

另外两条对写别的 DSH 插件也有用：

- **`.cmd` 一律纯 ASCII + CRLF**。cmd.exe 用 OEM 码页解析批处理且需要 CRLF；写成 UTF-8 + LF + 中文注释
  + `chcp 65001` 会出现「双击后窗口闪一下就消失、什么都没发生」。
- **cordis 的 `fiber.restart()` 热重载不吃宿主代码改动**（实测：改完 `lib/` 调 `reload` 仍执行旧模块）。
  宿主改动只能真正重启进程——本插件就是为此存在的。

## 日志与排障

全过程追加写 `~/.dsh/dsh-restart.log`，每一步都留痕（谁被 WMI 拉起、优雅关窗结果、taskkill 输出、
剩余进程数、是否发出重启、窗口几秒后回来、哨兵有没有出手）。

脚本自带演练模式，不杀进程、不重启：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\restart-dsh.ps1 -DryRun
```

## 已知限制

- **目前仅 Windows**（用到 WMI 创建进程与 `taskkill`；macOS 需换成 `launchctl`/`open` 的另一套实现）。
- 依赖官方 DSH Desktop 的默认安装路径；换安装位置请改脚本里的 `$exe`。
- 重启会**中断当前对话与正在跑的任务**——这是整机重启的固有代价。

## 卸载

```sh
dsh plugin --profile desktop remove @119-svg/dsh-restart
```

（记得先完全退出 DSH Desktop；`~/.dsh/dsh-restart.log` 与 `.pending` 标记可随手删掉。）

## License

MIT © 2026 119-svg
