import Foundation

/// Every user-facing string, kept in one place and in the same wording as the
/// web app and Android `strings.xml`.
enum Strings {
    static let appName = "MHub"
    // Tabs
    static let home = "主页"
    static let library = "资料库"
    static let search = "搜索"
    // Home
    static let recommendedPlaylists = "推荐歌单"
    static let recommendedSongs = "推荐歌曲"
    static let recentlyPlayed = "最近播放"
    static let refresh = "换一批"
    static let homeLoadFailed = "推荐加载失败"
    static let retry = "重试"
    static let settings = "设置"
    // Search
    static let searchPrompt = "歌曲、艺人"
    static let searchEmpty = "没有找到相关歌曲"
    static let searchHint = "搜索或选择一首音乐"
    // Library
    static let playlists = "歌单"
    static let localCache = "本地缓存"
    static let newPlaylist = "新建歌单"
    static let importPlaylist = "导入歌单"
    static let untitledPlaylist = "未命名歌单"
    static let playlistName = "歌单名称"
    static let rename = "重命名"
    static let deletePlaylist = "删除歌单"
    static let deletePlaylistConfirm = "删除后无法恢复，歌曲不会从缓存中删除。"
    static let emptyLibrary = "还没有歌单"
    static let emptyLibraryHint = "新建歌单，或粘贴 Apple Music、网易云的歌单链接导入。"
    static let emptyPlaylist = "歌单里还没有歌曲"
    static let importLinkPrompt = "歌单或专辑链接"
    static let importUnsupported = "目前支持 Apple Music 与网易云音乐的歌单、专辑链接"
    static let importButton = "导入"
    static let cancel = "取消"
    static let done = "完成"
    static let create = "创建"
    static let delete = "删除"
    static let songsCount = "%d 首歌曲"
    static let clearCache = "清除缓存"
    static let clearCacheConfirm = "清除所有已缓存的音频？歌单不受影响。"
    static let cacheEmpty = "还没有缓存的歌曲"
    // Song actions
    static let play = "播放"
    static let shuffle = "随机播放"
    static let playNext = "播放下一首"
    static let addToQueue = "添加到播放队列"
    static let addToPlaylist = "添加到歌单…"
    static let removeFromPlaylist = "从歌单删除"
    static let share = "分享"
    static let addAllToPlaylist = "添加到资料库"
    // Toasts (same wording as the web app)
    static func queuedAtEnd(_ title: String) -> String { "\(title) 已加入播放队列末尾" }
    static func alreadyQueued(_ title: String) -> String { "\(title) 已在播放队列中" }
    static func queuedNext(_ title: String) -> String { "\(title) 将在下一首播放" }
    static func queuedFirst(_ title: String) -> String { "\(title) 将排在队列最前" }
    static func nowPlayingAlready(_ title: String) -> String { "\(title) 正在播放" }
    static func addedToPlaylist(_ name: String, _ count: Int) -> String { count > 0 ? "已添加到「\(name)」" : "歌曲已在「\(name)」中" }
    static func imported(_ name: String, _ count: Int) -> String { "已导入「\(name)」，共 \(count) 首" }
    static func playbackRateLimited(_ seconds: Int) -> String { "切歌太频繁，\(seconds) 秒后自动播放" }
    static func importRateLimited(_ seconds: Int) -> String { "服务器繁忙，\(seconds) 秒后继续导入…" }
    static let noMoreRecommendations = "暂时没有更多新歌曲，可以重试"
    static let autoplayUnavailable = "自动续播暂时不可用，点击重试"
    static let autoplayUnsupported = "这个音乐来源暂不支持自动续播"
    // Player
    static let notPlaying = "未在播放"
    static let lyrics = "歌词"
    static let queue = "待播清单"
    static let playingNext = "接下来播放"
    static let autoplay = "自动播放"
    static let repeatMode = "重复"
    static let noLyrics = "暂无歌词"
    static let loadingLyrics = "正在加载歌词…"
    static let preparing = "正在准备音频…"
    static func replayIn(_ label: String) -> String { "以\(label)重新播放" }
    static let clearQueue = "清空队列"
    static let fromAutoplay = "自动播放推荐"
    // Settings
    static let server = "服务器"
    static let serverAddress = "服务器地址"
    static let serverPlaceholder = "https://music.example.com"
    static let serverFooter = "填写自托管的 MHub 地址。保存前会请求 /health 检查连接。"
    static let connect = "连接"
    static let connecting = "正在连接…"
    static let connectFailed = "无法连接服务器"
    static let welcome = "欢迎使用 MHub"
    static let welcomeHint = "连接你的 MHub 服务器，在一个队列里收听多个平台的音乐。"
    static let playback = "播放"
    static let quality = "音质"
    static let qualityFooter = "音质在开始播放时生效，不会打断正在播放的歌曲。"
    static let searchPlatform = "默认搜索平台"
    static let lyricScript = "歌词文字"
    static let lyricWordMode = "逐字效果"
    static let lyricWordModeFooter = "估算逐字会为只有整行时间的歌词按音节拆分；有原生逐字时间的歌词始终使用原生时间。"
    static let showTranslation = "显示翻译"
    static let showRoman = "显示音译"
    static let appearance = "外观"
    static let appearanceSystem = "跟随系统"
    static let appearanceLight = "浅色"
    static let appearanceDark = "深色"
    static let storage = "存储"
    static let cacheUsage = "音频缓存"
    static let cacheLimit = "缓存上限"
    static let about = "关于"
    static let version = "版本"
    static let sourceCode = "源代码"
    static let licenses = "开源许可"
    static let licenseText = "MHub 以 AGPL-3.0-only 发布。通过各平台获取的音乐、封面和歌词，版权归权利人所有。"
    // Account and library sync
    static let account = "账号"
    static let signIn = "登录"
    static let register = "注册"
    static let recoverySignIn = "用恢复码登录"
    static let signOut = "退出登录"
    static let signOutMessage = "本机保留当前歌单，之后的修改不再同步。"
    static func signOutPending(_ count: Int) -> String { "还有 \(count) 项修改未同步，退出后会丢失。" }
    static let syncNow = "立即同步"
    static let syncing = "同步中…"
    static let synced = "已同步"
    static let syncOffline = "离线"
    static func syncPending(_ count: Int) -> String { "待上传 \(count) 项" }
    static func syncFailed(_ message: String) -> String { "同步失败：\(message)" }
    static let accountFooter = "登录后歌单与网页版和其他设备同步。"
    static let accountLinkedFooter = "歌单的修改会自动上传，打开 App 时取回其他设备的修改。"
    static let registerFooter = "用户名 3–32 位字母、数字或 _ - .，密码至少 8 位。注册后会显示恢复码，忘记密码时用它登录。"
    static let username = "用户名"
    static let password = "密码"
    static let confirmPassword = "确认密码"
    static let recoveryCode = "恢复码"
    static let passwordMismatch = "两次输入的密码不一致"
    static let recoveryCodesTitle = "保存恢复码"
    static let recoveryCodesMessage = "每个恢复码只能用一次，忘记密码时用来登录。它们只显示这一次。"
    static let copy = "复制"
    // Updates
    static let autoUpdate = "自动检查更新"
    static let checkUpdate = "检查更新"
    static let checkingUpdate = "正在检查…"
    static let upToDate = "已是最新版本"
    static let updateCheckFailed = "检查更新失败，请稍后再试"
    static func updateAvailable(_ version: String) -> String { "发现新版本 \(version)" }
    static let later = "以后"
    // Download
    static let download = "下载"
    static func downloading(_ title: String) -> String { "正在下载《\(title)》…" }
    static func downloadInProgress(_ title: String) -> String { "《\(title)》正在下载" }
    static func downloadSaved(_ title: String) -> String { "《\(title)》已保存到「文件 › MHub」" }
    static func downloadFailed(_ message: String) -> String { "下载失败：\(message)" }
    static func serverBusyWait(_ seconds: Int) -> String { "服务器繁忙，\(seconds) 秒后继续…" }
    // Lyrics sharing and display settings
    static let shareLyrics = "分享歌词"
    static let shareLyricsMenu = "分享歌词…"
    static func shareLyricsHint(_ count: Int) -> String { "选择要分享的歌词，最多 \(count) 行" }
    static let shareLyricsEmpty = "选择下面的歌词"
    static let displaySettings = "歌词与外观"
    static let displaySettingsMenu = "歌词与外观…"
}
