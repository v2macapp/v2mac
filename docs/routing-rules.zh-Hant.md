# V2Mac: 路由規則

路由模式決定大部分流量如何處理。規則決定例外情況：哪些應用、網站、國家或地址**走代理**、**經由**另一台伺服器、**直連**或被**阻止**。規則在所有模式下都有效，並與 Bypass regions 並存。例如，你可以繞過伊朗，但仍讓某個伊朗網站走代理；或者在任何模式下都攔截廣告。

### 規則窗口

可以從側邊欄底部的玻璃按鈕、**Settings → Routing** 中的 **Open Rules…**、**Connections** 中的連線或菜單欄打開 **Rules**。左側列表從上往下檢查，第一條匹配的規則決定流量去向：

1. **Before your rules：** 本地網路（本機、局域網和 `printer.local` 等名稱始終直連）、**Block QUIC**（開關），以及使用代理端口的應用（在 Settings → Proxy 中設定）。
2. **My rules**，按你的順序。拖動可重新排序；每條都有開關。
3. **After your rules：** 路由模式自己的規則，然後是 **Everything else**（跟隨模式、Proxy、Direct 或 Block）。

所有修改都是草稿：修改過的規則帶有圓點，⌘Z 可撤銷，**Apply**（⌘S）保存並讓正在運行的連線重啓一次。窗口有未應用的修改時，關閉前會先詢問。

### 一條規則

- **Send to：** **Proxy**（當前連線的伺服器）、**Via** 某台伺服器或某個分組（分組中響應最快的伺服器）、**Direct** 或 **Block**。
- **Matches any of：** 應用、域名、精確名稱、關鍵字、地址和範圍、國家及服務列表。在同一個輸入框中輸入並從建議中選擇（已安裝的應用、帶條目數的服務、國家），一次粘貼多行，或點擊 **Browse…** 使用應用清單、服務卡片和世界地圖。右鍵點擊網站可將其改為精確名稱、關鍵字或正則表達式。點擊應用可查看它在此 Mac 上匹配什麼。
- **Only when**（可選）：端口（`443`、`8000-8100`）、TCP 或 UDP、協議（TLS、HTTP、QUIC、BitTorrent）和應用。每一項還必須滿足這些條件。例如，含 `*.example.com` 且“Only when: Safari”的規則只匹配 Safari 訪問該網站的流量。

只有“Only when”而沒有條目的規則會匹配所有此類流量：“UDP、BitTorrent → Direct”會讓種子流量直連。

**New Rule ▾** 可從模板開始：AI 服務、開發者工具、Apple 服務、社交和聊天、流媒體、地區網站直連、種子直連、廣告和跟蹤器。

### 經由另一台伺服器（Via）

**Via** 讓規則的流量經由與當前連線不同的伺服器，例如讓 AI 網站走另一個國家的伺服器。選擇一台伺服器，或選擇一個分組以使用其中響應最快的伺服器（每 30 秒檢查一次，失敗時由下一台接替）。

當它的伺服器都沒有響應時，規則的流量預設會**失敗**，絕不會走其他路徑。開啓 **If its servers fail, use the current server** 則改用當前伺服器。規則會顯示有多少台伺服器響應，全部無響應時菜單欄會發出警告。

### 流量去哪兒？

在搜索框中輸入網站、連結、地址或應用名稱。列表上方會顯示它的去向和原因，例如“api.github.com → Proxy，由 Developer（#8），匹配 geosite:github”，依據的是你當前的規則，無論是否已應用。

**Discovered** 列出在 Rules 或 Connections 窗口打開期間看到、且沒有任何規則覆蓋的應用和網站。用 **Add to** 加入到規則、拖到規則上，或選擇 **Ignore**。網站會以整個域名的形式建議（`api.github.com` 建議為 `github.com`）。

**規則醫生**（規則下方的玻璃按鈕）會檢查整個列表：錯誤、規則之間的衝突，以及可以精簡的規則，例如可由一個域名覆蓋的多個子域名、服務列表已包含的主機，或主機已在規則中的應用。**自動修復**會完成安全的操作；可能改變流量去向的項目列在**由你決定**下，並有各自的**修復**按鈕。在 Apply 之前不會有任何改變。

## 命令行與 AI 代理

可在 Settings → About 安裝 `v2mac`；Homebrew 會自動安裝。讀取命令會返回 revision；每次寫入都必須傳回該值，並建議先使用 `--dry-run`。CLI 會讓正在運行的應用驗證並保存更改，絕不會直接編輯偏好設定。代理應使用 `--json`；過期 revision 或規則窗口中未應用的草稿都會在不作任何更改的情況下失敗。

在 **Connections** 中右鍵點擊某行，可使用 **Add App to Rule**、**Add Host to Rule** 和 **Show Rule**。菜單欄面板會顯示前台應用、它的去向以及 **Add to Rule**。快捷指令中有 **Add to Rule** 操作。

### 導入和配置

**Import…**（⋯ 菜單）可讀取 Proxifier `.ppx` 配置、Clash / Mihomo、Shadowrocket / Surge、sing-box 和 Xray / v2rayN 規則，以及 V2Mac 導出的檔案。在確認之前不會加入任何內容。

- 指向 V2Mac 端口的 Proxifier 規則變為 **Proxy** 規則；**Direct** 和 **Block** 保持不變；使用其他代理或代理鏈的規則會被跳過並列出。
- Proxifier 的端口，以及 Clash 和 sing-box 的端口、網路和協議條件，會變為 **Only when**。
- Proxifier 的 **Block UDP 443** 會開啓 **Block QUIC**。
- 導入的規則排在你的規則之後，你的規則保持優先。

**Export** 導出全部或所選規則。**配置菜單**可保存多套命名規則，例如家裡和公司。

V2Mac 1.1 的規則會在首次啓動時遷移，效果與之前相同：1.1 中同時包含應用和主機的規則，會變為這些主機並加上“Only when”這些應用。

### 應用

應用可以寫成 `Spotify.app`、`com.spotify.client`、`*discord*`、進程名（`curl`）或完整路徑。應用規則適用於使用系統代理或 V2Mac 代理端口的應用；在 TUN 模式下適用於所有應用，包括命令行工具、Docker 和 Apple 的後台服務。

**關閉系統代理時**，設定為使用 V2Mac 代理端口的應用會跳過規則，直接使用伺服器（Settings → Proxy）。Connections 以橙色的 **App's proxy setting** 標記這些連線。**開啓系統代理時**，經該端口的所有流量都遵循規則。

第一條匹配的規則生效，因此即使某網站所在國家被繞過，Proxy 規則中的該網站仍走代理。**Direct** 模式只使用 Block 規則。完整的 Xray JSON 配置會先使用 V2Mac 的規則和模式，再以其自身路由作為兜底；Connections 以紫色的 **Config fallback** 標記這類流量。

**可以寫什麼**

規則的主機支持大多數教程、規則集和 Proxifier 使用的格式。逗號、空格和 `;` 也能分隔條目，以 `#`、`//` 或 `!` 開頭的行是注釋。

| 寫法 | 匹配 |
|---|---|
| `example.com`、`*.example.com`、`+.example.com`、`.ir` | 該域名及其所有子域名（`.ir` 表示所有 `.ir` 網站） |
| `full:www.example.com` | 僅這個完整域名 |
| `keyword:shop`、`*shop*` | 包含該關鍵詞的任何域名 |
| `regexp:^ads\d+\.` | 匹配正則表達式的域名 |
| `1.2.3.4`、`10.0.0.0/8`、`2001:db8::/32`、`10.0.0.1-10.0.0.9` | 單個地址或地址段，IPv4 或 IPv6 |
| `geosite:google`、`geosite:category-ads-all` | 核心 `geosite.dat` 中的站點列表（1500 多個） |
| `geoip:de`、`geoip:telegram` | `geoip.dat` 中某個國家或服務的地址 |
| `ext:region-ir-geosite.dat:ir` | 已下載地區規則包中的列表 |
| `DOMAIN-SUFFIX,example.com,DIRECT` | Clash 規則：`DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`DOMAIN-REGEX`、`IP-CIDR`、`IP-CIDR6`、`GEOIP`、`GEOSITE`（動作由規則決定，而不是 policy 列） |
| `0.0.0.0 ads.example.com` | hosts 檔案中的行 |
| `\|\|ads.example.com^` | Adblock 域名規則 |

無法識別的內容會顯示為紅色標記並被忽略，所以輸錯也不會導致無法連線。

**示例**

| 目標 | 發送到 | 條目 |
|---|---|---|
| 在所有模式下攔截廣告 | Block | `geosite:category-ads-all` |
| 即使繞過伊朗，AI 服務也走代理 | Proxy | `geosite:openai`、`geosite:anthropic`、`geosite:category-ai-!cn` |
| Apple 和 Microsoft 更新不走代理 | Direct | `geosite:apple`、`geosite:microsoft` |
| 直連公司內網 | Direct | `10.0.0.0/8`、`full:intranet.example.com` |
| 使用下載的 Clash 規則列表 | 任意 | 直接粘貼 `payload:` 中的行 |

如果規則引用了檔案中不存在的列表（例如 `geosite:nonexistent`），核心將無法啓動，記錄會指出是哪一條。規則窗口只提供實際存在的列表。

