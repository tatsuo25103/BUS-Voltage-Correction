# V0.5 開發初版

[English](RELEASE_NOTES_V0.5.md) · **繁體中文**

V0.5 是目前 Windows GUI 程式之前的 Console 開發基準版。原始 Python
程式未經修改，保存在 [`legacy/V0.5`](../legacy/V0.5/)。

## 初版功能

- 自動掃描 COM Port 並確認逆變器識別回覆。
- 使用 `2400 baud`、`8-N-1` 通訊。
- 送出一次逆變器開機程序後固定暖機 60 秒。
- 以 `max(VR, VS, VT) x 1.414` 計算 BUS Target。
- 依序校正 VDSPP、VDSPN、VMCUP、VMCUN。
- 固定使用 0.5 V 指令與正負 5 V 判定範圍。
- 具備基本無效修正計數、Console Summary 與文字 Log。

## 開發初版限制

- 必須另外安裝 Python 與 `pyserial`。
- 沒有桌面 GUI、安裝程式、Trend Chart 或 X CONTACTS 圖。
- 不同動作分別開啟 Serial Port，尚未使用共用受控 Session。
- 使用固定 60 秒暖機，沒有依 BUS 實際升壓狀態判斷啟動完成。
- 七個讀值必須一起穩定，尚未分開判斷四個校正通道。
- 四通道依序校正，沒有最後連續兩個穩定視窗確認。
- 尚未包含目前版本的累積無反應、反方向、完整報告、Manual Queue 與背景
  更新保護。

## 版本狀態

此版本以**歷史開發 Pre-release** 保存，不建議用於目前的正式維修。請使用
[最新正式版本](https://github.com/tatsuo25103/BUS-Voltage-Correction/releases/latest)。

原始程式 SHA-256：

```text
88BB158E38B267099EC5F66BE27FEF999E731FA79534DCC0719DF7D7CABF560D
```
