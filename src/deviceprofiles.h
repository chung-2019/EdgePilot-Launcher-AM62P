#pragma once

#include <QString>
#include <QStringList>

// ════════════════════════════════════════════════════════════════════════════
//  DeviceProfiles — 週邊裝置的識別字串，從程式碼移到設定檔
//
//  這裡承載的全是「第三方週邊實際播出來的 GAP Local Name」：掃描過濾的名稱
//  前綴，以及幾個韌體家族的名稱片段。它們是部署環境的資料，不是程式邏輯 ——
//  留在原始碼裡等於讓公開的 repo 帶著一份機型清單，而換一批機器也得重編。
//
//  尋找順序，第一個找得到的就用：
//    1. $EDGEPILOT_DEVICE_PROFILES 指到的檔案
//    2. 執行檔同目錄的 device-profiles.json
//    3. /etc/edgepilot/device-profiles.json
//
//  三個都沒有就是空設定。空設定不是錯誤狀態：每個 accessor 的註解都寫了它
//  空的時候行為退到哪裡，一律是「比較保守的那條路」，不會崩也不會誤判成別的
//  機型。第一次讀取時會用 qCInfo 記下實際採用的路徑（或「沒有設定檔」），
//  所以現場要確認吃到哪一份，看 journal 就夠。
//
//  設定檔長相（欄位意義見下方各 accessor 的註解）：
//    {
//      "memoryMeterNamePrefix": "",
//      "alwaysOnTokens": [],
//      "vendor1524Tokens": [],
//      "longHoldTokens": []
//    }
// ════════════════════════════════════════════════════════════════════════════
class DeviceProfiles {
public:
    // 第一次呼叫時載入，之後重複使用。設定檔不會在執行中重讀 —— 這些值只在
    // 連線流程的判斷裡用到，中途換掉只會讓同一條連線前後行為不一致。
    static const DeviceProfiles &instance();

    // 記憶體體溫計工具的掃描過濾前綴。launcher 本身已移除這支工具，不再讀取
    // 此值。
    //
    // 空字串 = 一台都不顯示。這是刻意的：那支工具連上之後會直接對 vendor
    // 1524 下命令，把不相干的週邊送進去只會得到一串失敗，不如什麼都不列，
    // 讓「設定檔沒設好」一眼就看得出來。
    QString memoryMeterNamePrefix() const { return m_memoryMeterPrefix; }

    // 常開韌體的名稱片段：連上後靠 bluez 讀 2A1C 的快取值，所以第一筆要丟。
    // 空清單 = 沒有任何裝置被當成常開，全部走 power-cycle 路徑（不丟第一筆）。
    QStringList alwaysOnTokens() const { return m_alwaysOn; }

    // vendor 1524 狀態機（0x54 開始 / 0xec 異常 / 0xff 結束）的名稱片段。
    // 空清單 = 不對任何裝置訂閱 1524，也不顯示倒數 HUD。
    QStringList vendor1524Tokens() const { return m_vendor1524; }

    // Long-hold HTS class（標準 HTS、連線不放、需要 loadConnParams 的那批）。
    // 空清單 = 沒有裝置會被自動切進 standard 模式。
    QStringList longHoldTokens() const { return m_longHold; }

    // name 正規化（去連字號、轉大寫）後是否命中任一 token。tokens 為空時
    // 一律回 false。
    static bool matches(const QString &name, const QStringList &tokens);

private:
    DeviceProfiles();
    void loadFrom(const QString &path);

    QString     m_memoryMeterPrefix;
    QStringList m_alwaysOn;
    QStringList m_vendor1524;
    QStringList m_longHold;
};
