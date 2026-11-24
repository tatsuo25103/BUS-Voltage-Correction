BUS Voltage Correction V0.8.1 - 免安裝版
=========================================

系統需求
--------
- Windows 10 或 Windows 11
- 已安裝正確的 USB 轉 RS232 驅動
- 不需要安裝 Python
- 不需要系統管理員權限

啟動方式
--------
1. 將 ZIP 內的整個資料夾解壓縮到電腦或 USB 隨身碟。
2. 雙擊「BUS Voltage Correction.vbs」。
3. 如果 Windows 禁止執行 VBS，請改為雙擊「open_desktop_gui.bat」。

請勿直接在 ZIP 預覽視窗內執行。必須先完整解壓縮，讓 assets 資料夾與
主程式保持在同一個資料夾內。

Log 與校正報告
---------------
紀錄會儲存在：

%LOCALAPPDATA%\BUS Voltage Correction\logs

可使用程式內的 Open Logs 按鈕直接開啟。

安全注意事項
------------
執行自動校正前，必須移除 AC Output、PV、BAT 與並聯訊號線，只保留
AC Grid 連接。

本程式會寫入逆變器校正參數，只適合受過訓練的維修人員使用。
