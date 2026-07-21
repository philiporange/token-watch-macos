import Foundation

// MARK: - App Language

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case japanese = "ja"
    case korean = "ko"
    case chineseSimplified = "zh-Hans"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .chineseSimplified: return "简体中文"
        }
    }
}

// MARK: - Localization

struct Loc {
    let lang: AppLanguage

    init(lang: AppLanguage = .english) {
        self.lang = lang
    }

    // MARK: - Properties

    var usage: String {
        switch lang {
        case .english: return "Usage"
        case .spanish: return "Uso"
        case .french: return "Utilisation"
        case .german: return "Nutzung"
        case .japanese: return "使用状況"
        case .korean: return "사용량"
        case .chineseSimplified: return "用量"
        }
    }

    var settings: String {
        switch lang {
        case .english: return "Settings"
        case .spanish: return "Ajustes"
        case .french: return "Réglages"
        case .german: return "Einstellungen"
        case .japanese: return "設定"
        case .korean: return "설정"
        case .chineseSimplified: return "设置"
        }
    }

    var autoRefresh: String {
        switch lang {
        case .english: return "Auto Refresh"
        case .spanish: return "Actualización automática"
        case .french: return "Actualisation automatique"
        case .german: return "Automatisch aktualisieren"
        case .japanese: return "自動更新"
        case .korean: return "자동 새로고침"
        case .chineseSimplified: return "自动刷新"
        }
    }

    var launchAtStartup: String {
        switch lang {
        case .english: return "Launch at Startup"
        case .spanish: return "Iniciar al arrancar"
        case .french: return "Lancer au démarrage"
        case .german: return "Beim Start starten"
        case .japanese: return "ログイン時に起動"
        case .korean: return "시작 시 실행"
        case .chineseSimplified: return "开机自启动"
        }
    }

    var geminiOtherModels: String {
        switch lang {
        case .english: return "Other Gemini Models"
        case .spanish: return "Otros modelos de Gemini"
        case .french: return "Autres modèles Gemini"
        case .german: return "Andere Gemini-Modelle"
        case .japanese: return "その他のGeminiモデル"
        case .korean: return "기타 Gemini 모델"
        case .chineseSimplified: return "其他 Gemini 模型"
        }
    }

    var geminiOtherModelsDesc: String {
        switch lang {
        case .english: return "Show Gemini's Claude and GPT model quotas alongside the Gemini models."
        case .spanish: return "Muestra las cuotas de los modelos Claude y GPT de Gemini junto a los modelos de Gemini."
        case .french: return "Afficher les quotas des modèles Claude et GPT de Gemini aux côtés des modèles Gemini."
        case .german: return "Kontingente für Gemini Claude- und GPT-Modelle neben den Gemini-Modellen anzeigen."
        case .japanese: return "Geminiモデルと並んで、GeminiのClaudeおよびGPTモデルの使用制限を表示します。"
        case .korean: return "Gemini 모델과 함께 Gemini의 Claude 및 GPT 모델 할당량을 표시합니다."
        case .chineseSimplified: return "在 Gemini 模型旁显示 Gemini 的 Claude 和 GPT 模型配额。"
        }
    }

    var menuBarAgentsDesc: String {
        switch lang {
        case .english: return "Ticked agents appear in the menu bar."
        case .spanish: return "Los agentes marcados aparecen en la barra de menú."
        case .french: return "Les agents cochés apparaissent dans la barre des menus."
        case .german: return "Aktivierte Agenten werden in der Menüleiste angezeigt."
        case .japanese: return "チェックを入れたエージェントがメニューバーに表示されます。"
        case .korean: return "선택된 에이전트가 메뉴 바에 표시됩니다."
        case .chineseSimplified: return "勾选的 Agent 将显示在菜单栏中。"
        }
    }

    var paceReveal: String {
        switch lang {
        case .english: return "Reveal by Pace"
        case .spanish: return "Mostrar según el ritmo"
        case .french: return "Afficher selon le rythme"
        case .german: return "Nach Tempo einblenden"
        case .japanese: return "ペースに応じて表示"
        case .korean: return "페이스별 표시"
        case .chineseSimplified: return "按节奏显示"
        }
    }

    var paceRevealDesc: String {
        switch lang {
        case .english: return "Show unticked agents in the menu bar while their pace is above or below these percentages."
        case .spanish: return "Muestra los agentes no marcados en la barra de menú mientras su ritmo esté por encima o por debajo de estos porcentajes."
        case .french: return "Afficher les agents non cochés dans la barre des menus lorsque leur rythme est supérieur ou inférieur à ces pourcentages."
        case .german: return "Deaktivierte Agenten in der Menüleiste anzeigen, wenn ihr Tempo über oder unter diesen Prozentwerten liegt."
        case .japanese: return "チェックが外れているエージェントのペースが設定割合を上回るか下回った場合にメニューバーに表示します。"
        case .korean: return "선택 해제된 에이전트의 페이스가 이 비율보다 높거나 낮을 때 메뉴 바에 표시합니다."
        case .chineseSimplified: return "当未勾选 Agent 的节奏高于或低于这些百分比时，在菜单栏中显示。"
        }
    }

    var enabled: String {
        switch lang {
        case .english: return "Enabled"
        case .spanish: return "Activado"
        case .french: return "Activé"
        case .german: return "Aktiviert"
        case .japanese: return "有効"
        case .korean: return "활성화됨"
        case .chineseSimplified: return "已启用"
        }
    }

    var paceAbove: String {
        switch lang {
        case .english: return "Above"
        case .spanish: return "Por encima"
        case .french: return "Au-dessus"
        case .german: return "Über"
        case .japanese: return "上限超過"
        case .korean: return "이상"
        case .chineseSimplified: return "高于"
        }
    }

    var paceBelow: String {
        switch lang {
        case .english: return "Below"
        case .spanish: return "Por debajo"
        case .french: return "En dessous"
        case .german: return "Unter"
        case .japanese: return "下限未満"
        case .korean: return "이하"
        case .chineseSimplified: return "低于"
        }
    }

    var resetReveal: String {
        switch lang {
        case .english: return "Reveal on Reset"
        case .spanish: return "Mostrar al reiniciar"
        case .french: return "Afficher lors de la réinitialisation"
        case .german: return "Bei Zurücksetzung einblenden"
        case .japanese: return "リセット時に表示"
        case .korean: return "초기화 시 표시"
        case .chineseSimplified: return "重置时显示"
        }
    }

    var resetRevealDesc: String {
        switch lang {
        case .english: return "Show unticked agents in the menu bar while their weekly or monthly usage is below this percentage."
        case .spanish: return "Muestra los agentes no marcados en la barra de menú mientras su uso semanal o mensual esté por debajo de este porcentaje."
        case .french: return "Afficher les agents non cochés dans la barre des menus lorsque leur utilisation hebdomadaire ou mensuelle est inférieure à ce pourcentage."
        case .german: return "Deaktivierte Agenten in der Menüleiste anzeigen, wenn ihre wöchentliche oder monatliche Nutzung unter diesem Prozentwert liegt."
        case .japanese: return "チェックが外れているエージェントの週次または月次使用率が指定割合を下回った場合にメニューバーに表示します。"
        case .korean: return "선택 해제된 에이전트의 주간 또는 월간 사용량이 이 비율 미만일 때 메뉴 바에 표시합니다."
        case .chineseSimplified: return "当未勾选 Agent 的周度或月度用量低于此百分比时，在菜单栏中显示。"
        }
    }

    var nearingResetReveal: String {
        switch lang {
        case .english: return "Reveal near Reset"
        case .spanish: return "Mostrar cerca del reinicio"
        case .french: return "Afficher avant la réinitialisation"
        case .german: return "Kurz vor Zurücksetzung einblenden"
        case .japanese: return "リセット直前に表示"
        case .korean: return "초기화 임박 시 표시"
        case .chineseSimplified: return "临近重置时显示"
        }
    }

    var nearingResetRevealDesc: String {
        switch lang {
        case .english: return "Show unticked agents in the menu bar when their weekly or monthly reset is less than this many hours away."
        case .spanish: return "Muestra los agentes no marcados en la barra de menú cuando falten menos de estas horas para su reinicio semanal o mensual."
        case .french: return "Afficher les agents non cochés dans la barre des menus lorsque leur réinitialisation hebdomadaire ou mensuelle a lieu dans moins de ce nombre d'heures."
        case .german: return "Deaktivierte Agenten in der Menüleiste anzeigen, wenn ihre wöchentliche oder monatliche Zurücksetzung weniger als diese Anzahl an Stunden entfernt ist."
        case .japanese: return "チェックが外れているエージェントの週次または月次リセットまで指定時間を切った場合にメニューバーに表示します。"
        case .korean: return "선택 해제된 에이전트의 주간 또는 월간 초기화까지 남은 시간이 지정된 시간 미만일 때 메뉴 바에 표시합니다."
        case .chineseSimplified: return "当未勾选 Agent 的周度或月度重置时间少于指定小时数时，在菜单栏中显示。"
        }
    }

    var usageBelow: String {
        switch lang {
        case .english: return "Usage below"
        case .spanish: return "Uso inferior a"
        case .french: return "Utilisation inférieure à"
        case .german: return "Nutzung unter"
        case .japanese: return "使用率低下"
        case .korean: return "사용량 미만"
        case .chineseSimplified: return "用量低于"
        }
    }

    var withinHours: String {
        switch lang {
        case .english: return "Within"
        case .spanish: return "En menos de"
        case .french: return "Dans les"
        case .german: return "Innerhalb von"
        case .japanese: return "残り時間"
        case .korean: return "남은 시간"
        case .chineseSimplified: return "在指定小时内"
        }
    }

    var general: String {
        switch lang {
        case .english: return "General"
        case .spanish: return "General"
        case .french: return "Général"
        case .german: return "Allgemein"
        case .japanese: return "一般"
        case .korean: return "일반"
        case .chineseSimplified: return "通用"
        }
    }

    var refreshAll: String {
        switch lang {
        case .english: return "Refresh All"
        case .spanish: return "Actualizar todo"
        case .french: return "Tout actualiser"
        case .german: return "Alle aktualisieren"
        case .japanese: return "すべて更新"
        case .korean: return "모두 새로고침"
        case .chineseSimplified: return "刷新全部"
        }
    }

    var providers: String {
        switch lang {
        case .english: return "Providers"
        case .spanish: return "Proveedores"
        case .french: return "Fournisseurs"
        case .german: return "Anbieter"
        case .japanese: return "プロバイダー"
        case .korean: return "제공자"
        case .chineseSimplified: return "服务商"
        }
    }

    var agents: String {
        switch lang {
        case .english: return "Agents"
        case .spanish: return "Agentes"
        case .french: return "Agents"
        case .german: return "Agenten"
        case .japanese: return "エージェント"
        case .korean: return "에이전트"
        case .chineseSimplified: return "Agent"
        }
    }

    var language: String {
        switch lang {
        case .english: return "Language"
        case .spanish: return "Idioma"
        case .french: return "Langue"
        case .german: return "Sprache"
        case .japanese: return "言語"
        case .korean: return "언어"
        case .chineseSimplified: return "语言"
        }
    }

    var openSettings: String {
        switch lang {
        case .english: return "Open Settings"
        case .spanish: return "Abrir Ajustes"
        case .french: return "Ouvrir les Réglages"
        case .german: return "Einstellungen öffnen"
        case .japanese: return "設定を開く"
        case .korean: return "설정 열기"
        case .chineseSimplified: return "打开设置"
        }
    }

    var noAgentsMessage: String {
        switch lang {
        case .english: return "No authenticated agents are available."
        case .spanish: return "No hay agentes autenticados disponibles."
        case .french: return "Aucun agent authentifié n'est disponible."
        case .german: return "Keine authentifizierten Agenten verfügbar."
        case .japanese: return "認証済みのエージェントがありません。"
        case .korean: return "인증된 에이전트를 사용할 수 없습니다."
        case .chineseSimplified: return "没有可用的已认证 Agent。"
        }
    }

    var noAgentsHint: String {
        switch lang {
        case .english: return "Open Settings to see availability and setup instructions."
        case .spanish: return "Abre Ajustes para ver la disponibilidad y las instrucciones de configuración."
        case .french: return "Ouvrez les Réglages pour voir la disponibilité et les instructions de configuration."
        case .german: return "Öffne die Einstellungen, um Verfügbarkeit und Einrichtungsanweisungen zu sehen."
        case .japanese: return "設定を開いて利用可能性とセットアップ手順を確認してください。"
        case .korean: return "설정을 열어 사용 가능 여부와 설정 지침을 확인하세요."
        case .chineseSimplified: return "打开“设置”以查看可用性和设置说明。"
        }
    }

    var autoRefreshDesc: String {
        switch lang {
        case .english: return "Default is 5 minutes. Manual disables background refresh and uses the refresh button only."
        case .spanish: return "El valor predeterminado es 5 minutos. Manual deshabilita la actualización en segundo plano y usa solo el botón de actualización."
        case .french: return "La valeur par défaut est de 5 minutes. Manuel désactive l'actualisation en arrière-plan et utilise uniquement le bouton d'actualisation."
        case .german: return "Standard ist 5 Minuten. Manuell deaktiviert die Hintergrundaktualisierung und verwendet nur die Schaltfläche zum Aktualisieren."
        case .japanese: return "デフォルトは5分です。手動にするとバックグラウンド更新が無効になり、更新ボタンのみ使用されます。"
        case .korean: return "기본값은 5분입니다. 수동은 백그라운드 새로고침을 비활성화하고 새로고침 버튼만 사용합니다."
        case .chineseSimplified: return "默认为 5 分钟。手动模式将禁用后台刷新，仅使用刷新按钮。"
        }
    }

    var launchAtStartupDesc: String {
        switch lang {
        case .english: return "Start Token Watch automatically when you log in to your Mac."
        case .spanish: return "Inicia Token Watch automáticamente al iniciar sesión en tu Mac."
        case .french: return "Lancer Token Watch automatiquement lorsque vous vous connectez à votre Mac."
        case .german: return "Token Watch automatisch starten, wenn du dich auf deinem Mac anmeldest."
        case .japanese: return "MacにログインしたときにToken Watchを自動的に起動します。"
        case .korean: return "Mac에 로그인할 때 Token Watch를 자동으로 시작합니다."
        case .chineseSimplified: return "在登录 Mac 时自动启动 Token Watch。"
        }
    }

    var launchAtStartupApprovalDesc: String {
        switch lang {
        case .english: return "Token Watch is added to Login Items, but macOS still requires approval in System Settings."
        case .spanish: return "Token Watch se añade a los Ítems del inicio de sesión, pero macOS requiere aprobación en los Ajustes del Sistema."
        case .french: return "Token Watch est ajouté aux éléments d'ouverture de session, mais macOS requiert toujours une approbation dans les Réglages Système."
        case .german: return "Token Watch wird zu den Anmeldeobjekten hinzugefügt, macOS erfordert jedoch weiterhin die Genehmigung in den Systemeinstellungen."
        case .japanese: return "Token Watchはログイン項目に追加されますが、macOSのシステム設定での承認が必要です。"
        case .korean: return "Token Watch가 로그인 항목에 추가되지만 macOS 시스템 설정에서 승인이 필요합니다."
        case .chineseSimplified: return "Token Watch 已添加到登录项，但 macOS 仍需要在“系统设置”中予以批准。"
        }
    }

    var launchAtStartupUnsupportedDesc: String {
        switch lang {
        case .english: return "Launch at startup is available only from the packaged app."
        case .spanish: return "Iniciar al arrancar solo está disponible desde la aplicación empaquetada."
        case .french: return "Le lancement au démarrage est disponible uniquement depuis l'application empaquetée."
        case .german: return "Der Start beim Hochfahren ist nur in der verpackten App verfügbar."
        case .japanese: return "ログイン時起動はパッケージ化されたアプリからのみ利用可能です。"
        case .korean: return "시작 시 실행은 패키지된 앱에서만 사용할 수 있습니다."
        case .chineseSimplified: return "开机自启动仅在打包的应用中可用。"
        }
    }

    var providersDesc: String {
        switch lang {
        case .english: return "Codex uses codex app-server. Claude and Gemini read local CLI credentials; Gemini uses agy's quota service."
        case .spanish: return "Codex usa codex app-server. Claude y Gemini leen credenciales locales de la CLI; Gemini usa el servicio de cuotas de agy."
        case .french: return "Codex utilise codex app-server. Claude et Gemini lisent les identifiants CLI locaux ; Gemini utilise le service de quota d'agy."
        case .german: return "Codex verwendet codex app-server. Claude und Gemini lesen lokale CLI-Zugangsdaten; Gemini nutzt den Quota-Dienst von agy."
        case .japanese: return "Codexはcodex app-serverを使用します。ClaudeおよびGeminiはローカルのCLI資格情報を読み込みます。Geminiはagyのクォータサービスを使用します。"
        case .korean: return "Codex는 codex app-server를 사용합니다. Claude 및 Gemini는 로컬 CLI 자격 증명을 읽고, Gemini는 agy의 할당량 서비스를 사용합니다."
        case .chineseSimplified: return "Codex 使用 codex app-server。Claude 和 Gemini 读取本地 CLI 凭据；Gemini 使用 agy 的配额服务。"
        }
    }

    // MARK: - Functions

    func windowLabel(_ kind: UsageWindowKind) -> String {
        switch kind {
        case .fiveHour:
            switch lang {
            case .korean: return "5시간"
            default: return "5h"
            }
        case .weekly:
            switch lang {
            case .english: return "Week"
            case .spanish: return "Semana"
            case .french: return "Semaine"
            case .german: return "Woche"
            case .japanese: return "週"
            case .korean: return "주간"
            case .chineseSimplified: return "周"
            }
        case .modelWeekly:
            switch lang {
            case .english: return "Model week"
            case .spanish: return "Semana del modelo"
            case .french: return "Semaine du modèle"
            case .german: return "Modellwoche"
            case .japanese: return "モデルの週"
            case .korean: return "모델 주간"
            case .chineseSimplified: return "模型周"
            }
        case .monthly:
            switch lang {
            case .english: return "Month"
            case .spanish: return "Mes"
            case .french: return "Mois"
            case .german: return "Monat"
            case .japanese: return "月"
            case .korean: return "월간"
            case .chineseSimplified: return "月"
            }
        }
    }

    func refreshLabel(_ interval: AutoRefreshInterval) -> String {
        if lang == .english {
            return interval.label
        }

        switch interval {
        case .manual:
            switch lang {
            case .spanish: return "Manual"
            case .french: return "Manuel"
            case .german: return "Manuell"
            case .japanese: return "手動"
            case .korean: return "수동"
            case .chineseSimplified: return "手动"
            default: return interval.label
            }
        case .oneMinute:
            switch lang {
            case .spanish: return "1 minuto"
            case .french: return "1 minute"
            case .german: return "1 Minute"
            case .japanese: return "1分"
            case .korean: return "1분"
            case .chineseSimplified: return "1 分钟"
            default: return interval.label
            }
        case .twoMinutes:
            switch lang {
            case .spanish: return "2 minutos"
            case .french: return "2 minutes"
            case .german: return "2 Minuten"
            case .japanese: return "2分"
            case .korean: return "2분"
            case .chineseSimplified: return "2 分钟"
            default: return interval.label
            }
        case .fiveMinutes:
            switch lang {
            case .spanish: return "5 minutos"
            case .french: return "5 minutes"
            case .german: return "5 Minuten"
            case .japanese: return "5分"
            case .korean: return "5분"
            case .chineseSimplified: return "5 分钟"
            default: return interval.label
            }
        case .tenMinutes:
            switch lang {
            case .spanish: return "10 minutos"
            case .french: return "10 minutes"
            case .german: return "10 Minuten"
            case .japanese: return "10分"
            case .korean: return "10분"
            case .chineseSimplified: return "10 分钟"
            default: return interval.label
            }
        case .fifteenMinutes:
            switch lang {
            case .spanish: return "15 minutos"
            case .french: return "15 minutes"
            case .german: return "15 Minuten"
            case .japanese: return "15分"
            case .korean: return "15분"
            case .chineseSimplified: return "15 分钟"
            default: return interval.label
            }
        case .thirtyMinutes:
            switch lang {
            case .spanish: return "30 minutos"
            case .french: return "30 minutes"
            case .german: return "30 Minuten"
            case .japanese: return "30分"
            case .korean: return "30분"
            case .chineseSimplified: return "30 分钟"
            default: return interval.label
            }
        }
    }

    func displayMessage(_ message: String?) -> String {
        guard let message = message else {
            return "—"
        }
        if message == "Loading…" {
            switch lang {
            case .english: return "Loading…"
            case .spanish: return "Cargando…"
            case .french: return "Chargement…"
            case .german: return "Laden…"
            case .japanese: return "読み込み中…"
            case .korean: return "로딩 중…"
            case .chineseSimplified: return "加载中…"
            }
        }
        return message
    }

    func insightMessage(delta: Double) -> String {
        let pct = Int(round(abs(delta)))
        if delta < -5 {
            switch lang {
            case .english: return "\(pct)% over pace"
            case .spanish: return "\(pct)% por encima del ritmo"
            case .french: return "\(pct)% au-dessus du rythme"
            case .german: return "\(pct)% über dem Tempo"
            case .japanese: return "ペース超過 \(pct)%"
            case .korean: return "페이스 초과 \(pct)%"
            case .chineseSimplified: return "超出进度 \(pct)%"
            }
        } else if delta > 5 {
            switch lang {
            case .english: return "\(pct)% to spare"
            case .spanish: return "\(pct)% de margen"
            case .french: return "\(pct)% de marge"
            case .german: return "\(pct)% Reserve"
            case .japanese: return "余裕 \(pct)%"
            case .korean: return "여유 \(pct)%"
            case .chineseSimplified: return "剩余额度 \(pct)%"
            }
        } else {
            switch lang {
            case .english: return "On pace"
            case .spanish: return "Al ritmo"
            case .french: return "Dans le rythme"
            case .german: return "Im Tempo"
            case .japanese: return "順調"
            case .korean: return "페이스 유지"
            case .chineseSimplified: return "符合进度"
            }
        }
    }

    func statusTitle(_ status: AgentStatus) -> String {
        switch status.availability {
        case .loading:
            switch lang {
            case .english: return "Checking…"
            case .spanish: return "Comprobando…"
            case .french: return "Vérification…"
            case .german: return "Prüfen…"
            case .japanese: return "確認中…"
            case .korean: return "확인 중…"
            case .chineseSimplified: return "检查中…"
            }
        case .available:
            switch lang {
            case .english: return "Available"
            case .spanish: return "Disponible"
            case .french: return "Disponible"
            case .german: return "Verfügbar"
            case .japanese: return "利用可能"
            case .korean: return "사용 가능"
            case .chineseSimplified: return "可用"
            }
        case .missingAuth:
            switch lang {
            case .english: return "Auth not found"
            case .spanish: return "Autenticación no encontrada"
            case .french: return "Auth introuvable"
            case .german: return "Auth nicht gefunden"
            case .japanese: return "認証が見つかりません"
            case .korean: return "인증을 찾을 수 없음"
            case .chineseSimplified: return "未找到认证"
            }
        case .accessDenied:
            switch lang {
            case .english: return "Access denied"
            case .spanish: return "Acceso denegado"
            case .french: return "Accès refusé"
            case .german: return "Zugriff verweigert"
            case .japanese: return "アクセスが拒否されました"
            case .korean: return "액세스 거부됨"
            case .chineseSimplified: return "拒绝访问"
            }
        case .sessionExpired:
            switch lang {
            case .english: return "Session expired"
            case .spanish: return "Sesión caducada"
            case .french: return "Session expirée"
            case .german: return "Sitzung abgelaufen"
            case .japanese: return "セッション期限切れ"
            case .korean: return "세션 만료됨"
            case .chineseSimplified: return "会话已过期"
            }
        case .notInstalled:
            switch lang {
            case .english: return "Not installed"
            case .spanish: return "No instalado"
            case .french: return "Non installé"
            case .german: return "Nicht installé" // Wait! french "Non installé" vs German "Nicht installiert"
            case .japanese: return "未インストール"
            case .korean: return "설치되지 않음"
            case .chineseSimplified: return "未安装"
            }
        case .notLoggedIn:
            switch lang {
            case .english: return "Not signed in"
            case .spanish: return "Sesión no iniciada"
            case .french: return "Non connecté"
            case .german: return "Nicht angemeldet"
            case .japanese: return "未サインイン"
            case .korean: return "로그인되지 않음"
            case .chineseSimplified: return "未登录"
            }
        case .error:
            switch lang {
            case .english: return "Error"
            case .spanish: return "Error"
            case .french: return "Erreur"
            case .german: return "Fehler"
            case .japanese: return "エラー"
            case .korean: return "오류"
            case .chineseSimplified: return "错误"
            }
        }
    }

    func statusInstruction(_ status: AgentStatus) -> String? {
        switch (status.provider, status.availability) {
        case (.claude, .missingAuth):
            switch lang {
            case .english: return "Run `claude` in Terminal, then run `/login`."
            case .spanish: return "Ejecuta `claude` en la Terminal y luego ejecuta `/login`."
            case .french: return "Exécutez `claude` dans le Terminal, puis exécutez `/login`."
            case .german: return "Führe `claude` im Terminal aus und führe dann `/login` aus."
            case .japanese: return "ターミナルで `claude` を実行し、次に `/login` を実行してください。"
            case .korean: return "터미널에서 `claude`를 실행한 후 `/login`을 실행하세요."
            case .chineseSimplified: return "在终端中运行 `claude`，然后运行 `/login`。"
            }
        case (.claude, .accessDenied):
            switch lang {
            case .english: return "Allow Keychain access for `Claude Code-credentials`, or run `claude` in Terminal and then `/login`."
            case .spanish: return "Permite el acceso al Llavero para `Claude Code-credentials`, o ejecuta `claude` en la Terminal y luego `/login`."
            case .french: return "Autorisez l'accès au Trousseau pour `Claude Code-credentials`, ou exécutez `claude` dans le Terminal puis `/login`."
            case .german: return "Erlaube den Schlüsselbund-Zugriff für `Claude Code-credentials` oder führe `claude` im Terminal und dann `/login` aus."
            case .japanese: return "`Claude Code-credentials` のキーチェーンアクセスを許可するか、ターミナルで `claude` を実行してから `/login` を実行してください。"
            case .korean: return "`Claude Code-credentials`에 대한 키체인 접근을 허용하거나 터미널에서 `claude`를 실행한 후 `/login`을 실행하세요."
            case .chineseSimplified: return "允许对 `Claude Code-credentials` 的钥匙串访问，或在终端中运行 `claude` 然后运行 `/login`。"
            }
        case (.claude, .sessionExpired):
            switch lang {
            case .english: return "Run `claude` in Terminal, then run `/login` again."
            case .spanish: return "Ejecuta `claude` en la Terminal y luego ejecuta `/login` de nuevo."
            case .french: return "Exécutez `claude` dans le Terminal, puis exécutez à nouveau `/login`."
            case .german: return "Führe `claude` im Terminal aus und führe dann erneut `/login` aus."
            case .japanese: return "ターミナルで `claude` を実行し、再度 `/login` を実行してください。"
            case .korean: return "터미널에서 `claude`를 실행한 후 `/login`을 다시 실행하세요."
            case .chineseSimplified: return "在终端中运行 `claude`，然后再次运行 `/login`。"
            }
        case (.codex, .notInstalled):
            switch lang {
            case .english: return "Install the Codex CLI and make sure `codex` is on PATH."
            case .spanish: return "Instala la CLI de Codex y asegúrate de que `codex` esté en el PATH."
            case .french: return "Installez la CLI Codex et assurez-vous que `codex` est dans le PATH."
            case .german: return "Installiere die Codex-CLI und stelle sicher, dass `codex` im PATH enthalten ist."
            case .japanese: return "Codex CLIをインストールし、`codex` がPATHに含まれていることを確認してください。"
            case .korean: return "Codex CLI를 설치하고 `codex`가 PATH에 있는지 확인하세요."
            case .chineseSimplified: return "安装 Codex CLI 并确保 `codex` 在 PATH 中。"
            }
        case (.codex, .notLoggedIn):
            switch lang {
            case .english: return "Run `codex` in Terminal, then run `/login`."
            case .spanish: return "Ejecuta `codex` en la Terminal y luego ejecuta `/login`."
            case .french: return "Exécutez `codex` dans le Terminal, puis exécutez `/login`."
            case .german: return "Führe `codex` im Terminal aus und führe dann `/login` aus."
            case .japanese: return "ターミナルで `codex` を実行し、次に `/login` を実行してください。"
            case .korean: return "터미널에서 `codex`를 실행한 후 `/login`을 실행하세요."
            case .chineseSimplified: return "在终端中运行 `codex`，然后运行 `/login`。"
            }
        case (.gemini, .missingAuth), (.gemini, .notLoggedIn):
            switch lang {
            case .english: return "Run `agy` in Terminal and sign in, then refresh."
            case .spanish: return "Ejecuta `agy` en la Terminal e inicia sesión, luego actualiza."
            case .french: return "Exécutez `agy` dans le Terminal et connectez-vous, puis actualisez."
            case .german: return "Führe `agy` im Terminal aus und melde dich an, danach aktualisieren."
            case .japanese: return "ターミナルで `agy` を実行してサインインし、更新してください。"
            case .korean: return "터미널에서 `agy`를 실행하여 로그인한 후 새로고침하세요."
            case .chineseSimplified: return "在终端中运行 `agy` 并登录，然后刷新。"
            }
        case (.gemini, .accessDenied):
            switch lang {
            case .english: return "Allow Keychain access for the `gemini` credential, then refresh."
            case .spanish: return "Permite el acceso al Llavero para las credenciales de `gemini`, luego actualiza."
            case .french: return "Autorisez l'accès au Trousseau pour l'identifiant `gemini`, puis actualisez."
            case .german: return "Erlaube den Schlüsselbund-Zugriff für Anmeldedaten von `gemini`, danach aktualisieren."
            case .japanese: return "`gemini` 資格情報のキーチェーンアクセスを許可し、更新してください。"
            case .korean: return "`gemini` 자격 증명에 대한 키체인 접근을 허용한 후 새로고침하세요."
            case .chineseSimplified: return "允许对 `gemini` 凭据的钥匙串访问，然后刷新。"
            }
        case (.gemini, .sessionExpired):
            switch lang {
            case .english: return "Run `agy` in Terminal and sign in again."
            case .spanish: return "Ejecuta `agy` en la Terminal e inicia sesión de nuevo."
            case .french: return "Exécutez `agy` dans le Terminal et connectez-vous à nouveau."
            case .german: return "Führe `agy` im Terminal aus und melde dich erneut an."
            case .japanese: return "ターミナルで `agy` を実行して再度サインインしてください。"
            case .korean: return "터미널에서 `agy`를 실행하여 다시 로그인하세요."
            case .chineseSimplified: return "在终端中运行 `agy` 并重新登录。"
            }
        case (.zai, .missingAuth), (.zai, .notLoggedIn):
            switch lang {
            case .english: return "Set `ZAI_API_KEY` in `~/.env`, then refresh."
            case .spanish: return "Configura `ZAI_API_KEY` en `~/.env`, luego actualiza."
            case .french: return "Définissez `ZAI_API_KEY` dans `~/.env`, puis actualisez."
            case .german: return "Setze `ZAI_API_KEY` in `~/.env` und aktualisiere dann."
            case .japanese: return "`~/.env` に `ZAI_API_KEY` を設定し、更新してください。"
            case .korean: return "`~/.env`에 `ZAI_API_KEY`를 설정한 후 새로고침하세요."
            case .chineseSimplified: return "在 `~/.env` 中设置 `ZAI_API_KEY`，然后刷新。"
            }
        default:
            return nil
        }
    }
}
