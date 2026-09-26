# EVM runtime assets

跨 host 機器搬遷時跟著專案走的 EVM 端 helper 檔。
**只在「第一次部署到新 EVM」時用一次**；後續 build/deploy 走
`../build.sh` + `../deploy.sh` 即可。

## 內容

| 檔案 | 用途 | EVM 目的地 |
| --- | --- | --- |
| `run-whetstone.sh` | tty-aware 版的 whetstone 跑分 script，QProcess 跑時會跳過 `read -n 1` / `less -R` | `/opt/ti-apps-launcher/run-whetstone.sh` |
| `99-noto-cjk-fallback.conf` | fontconfig fallback for device names and system text | `/etc/fonts/conf.d/99-noto-cjk-fallback.conf` |
| `push-evm-assets.sh` | 一次部署上面兩個 + cursor theme + Noto 字型 | (在 host 跑) |

## 用法

```bash
EVM_IP=<board address> ./push-evm-assets.sh
```

抓 host 上的 Adwaita cursor + 從 jsDelivr 下載 Noto Sans TC，全部 push 到 EVM。
跑完一次後就不用再執行（除非換新 EVM 或 EVM 重 flash）。
