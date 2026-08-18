# V0.7.1

[English](RELEASE_NOTES_V0.7.1.md) · **繁體中文**

## 使用體驗

- 加入 MES Logo，並把必要圖片封裝到安裝檔。
- 啟動時在背景檢查 GitHub Releases。
- 校正、排程 Manual Correction 或安全對話框尚未結束時不顯示更新提示；
  離線檢查不會中斷作業。

## 校正與報告

- 保存每個通道第一次自動修正前確認穩定的電壓。
- Summary 與報告區分 Startup sample 與校正前穩定電壓。
- 非預期錯誤會嘗試最後回讀並產生包含 Event Log 的報告。
- 報告寫入失敗不會遮蔽原始錯誤與「只接 AC Grid」提醒。
- 狀態可區分 `Ready`、`Running`、`Manual`、`Calibrating`。

## 保留的控制邏輯

- 所有動作共用一個受控 Serial Connection，通訊為 `2400 baud`、`8-N-1`。
- BUS 未啟動時每 10 秒重送開機指令。
- 四通道分別判斷穩定度，自動修正固定使用 0.5 V。
- 連續無效果、反方向或惡化時停止並顯示安全提醒。
- 連續兩個穩定視窗四通道都合格才成功。
- 成功與失敗報告都包含 Summary、修正步驟與 Event Log。

## 安裝與驗證

- 更新每位 Windows 使用者獨立安裝的 Setup；不需要 Python 或 `pyserial`。
- 全新暫存安裝確認主程式、啟動器、文件、Uninstaller、Logo 齊全。
- PowerShell 語法、版本比較與穩定值選擇測試通過。
- 上傳後確認 GitHub Release Metadata 與 Installer Asset。
- 本次文件整理沒有另外執行新的逆變器實機校正。

## 下載

[下載 V0.7.1](https://github.com/tatsuo25103/BUS-Voltage-Correction/releases/tag/v0.7.1)

安裝檔 SHA-256：

```text
91855467912F1030C9A7B0D58844EEA1E636D6F467D49A32163B98B2733828D6
```
