"""
    NotifyOnDone

長時間計算の完了・エラーをSlack（Incoming Webhook）で通知するマクロを提供します。

# Webhook URLの設定（優先順位順）
1. set_webhook!() でスクリプト内から設定
2. 環境変数 SLACK_WEBHOOK_URL（~/.bashrc、startup.jl など）

複数人が同じアカウントを共有する環境では set_webhook!() を使います。

# 使い方
    using NotifyOnDone

    # 共有サーバーで自分のURLを設定する場合
    set_webhook!("https://hooks.slack.com/services/XXX/YYY/ZZZ")

    @notify my_heavy_function(data)

    @notify "モデル学習" begin
        train_model(X, y, epochs=500)
    end
"""
module NotifyOnDone

export @notify, set_webhook!

using Dates
import Printf: @sprintf

# ----------------------------------------------------------------
# Webhook URL の管理
# ----------------------------------------------------------------

# スクリプトから set_webhook!() で設定された URL を保持する
const _WEBHOOK_URL = Ref{String}("")

"""
    set_webhook!(url::String)

Webhook URLをスクリプト内から設定します。
環境変数 SLACK_WEBHOOK_URL より優先されます。

# 例
```julia
using NotifyOnDone
set_webhook!("https://hooks.slack.com/services/XXX/YYY/ZZZ")

@notify "計算" my_func()
```
"""
function set_webhook!(url::String)
    startswith(url, "https://hooks.slack.com/") ||
        @warn "set_webhook!: 想定外の形式のURLです: $url"
    _WEBHOOK_URL[] = url
    return nothing
end

"""
    _webhook_url() -> String

Webhook URLを以下の優先順位で取得します：
1. set_webhook!() で設定された値
2. 環境変数 SLACK_WEBHOOK_URL

どちらも未設定の場合は ArgumentError を投げます。
"""
function _webhook_url()::String
    # 1. set_webhook!() で設定された値を優先
    url = _WEBHOOK_URL[]
    if !isempty(url)
        return url
    end

    # 2. 環境変数にフォールバック
    url = get(ENV, "SLACK_WEBHOOK_URL", "")
    if !isempty(url)
        startswith(url, "https://hooks.slack.com/") ||
            @warn "SLACK_WEBHOOK_URL が想定外の形式です: $url"
        return url
    end

    # どちらも未設定
    throw(ArgumentError(
        "Webhook URLが設定されていません。以下のいずれかで設定してください:\n" *
        "  スクリプト内: set_webhook!(\"https://hooks.slack.com/services/...\")\n" *
        "  環境変数: export SLACK_WEBHOOK_URL=\"https://hooks.slack.com/services/...\""
    ))
end

"""
    _escape_json(s) -> String

JSON文字列中で問題になる文字をエスケープします。
"""
function _escape_json(s::AbstractString)::String
    s = replace(s, "\\" => "\\\\")
    s = replace(s, "\"" => "\\\"")
    s = replace(s, "\n" => "\\n")
    s = replace(s, "\r" => "\\r")
    s = replace(s, "\t" => "\\t")
    return s
end

"""
    _hostname() -> String

実行マシンのホスト名を取得します（通知の識別に利用）。
"""
function _hostname()::String
    try
        strip(read(`hostname`, String))
    catch
        "unknown host"
    end
end

"""
    _format_elapsed(seconds::Float64) -> String

経過秒数を読みやすい文字列に変換します。
例: 3661.0 => "1時間 1分 1.0秒"
"""
function _format_elapsed(seconds::Float64)::String
    seconds < 60   && return @sprintf("%.2f 秒", seconds)
    seconds < 3600 && return @sprintf("%d 分 %.1f 秒", floor(Int, seconds/60), seconds % 60)
    h = floor(Int, seconds / 3600)
    m = floor(Int, (seconds % 3600) / 60)
    s = seconds % 60
    return @sprintf("%d 時間 %d 分 %.1f 秒", h, m, s)
end

# ----------------------------------------------------------------
# Slack送信
# ----------------------------------------------------------------

"""
    _send_slack(payload_json::String)

Slack Incoming Webhook へJSONペイロードをPOSTします。
`curl` を使うことで外部依存ゼロで動作します。
"""
function _send_slack(payload_json::String)
    url = _webhook_url()
    try
        cmd = `curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" --data-binary $(payload_json) $(url)`
        http_status = strip(read(cmd, String))
        if http_status != "200"
            @warn "Slack通知の送信に失敗しました (HTTP $http_status)"
        end
    catch e
        @warn "Slack通知の送信中にエラーが発生しました: $e"
    end
end

"""
    _notify_success(label::String, elapsed::Float64)

成功通知をSlackへ送信します。
"""
function _notify_success(label::String, elapsed::Float64)
    host     = _escape_json(_hostname())
    lbl      = _escape_json(label)
    time_str = _escape_json(_format_elapsed(elapsed))
    ts       = _escape_json(string(now()))

    payload = """{"text":":white_check_mark: *計算完了*","attachments":[{"color":"good","fields":[{"title":"ラベル","value":"$(lbl)","short":true},{"title":"経過時間","value":"$(time_str)","short":true},{"title":"ホスト","value":"$(host)","short":true},{"title":"完了時刻","value":"$(ts)","short":true}]}]}"""
    _send_slack(payload)
end

"""
    _notify_error(label::String, elapsed::Float64, err)

エラー通知をSlackへ送信します。
"""
function _notify_error(label::String, elapsed::Float64, err)
    host     = _escape_json(_hostname())
    lbl      = _escape_json(label)
    time_str = _escape_json(_format_elapsed(elapsed))
    ts       = _escape_json(string(now()))
    err_msg  = _escape_json(sprint(showerror, err))

    payload = """{"text":":x: *エラーが発生しました*","attachments":[{"color":"danger","fields":[{"title":"ラベル","value":"$(lbl)","short":true},{"title":"経過時間","value":"$(time_str)","short":true},{"title":"ホスト","value":"$(host)","short":true},{"title":"発生時刻","value":"$(ts)","short":true},{"title":"エラー内容","value":"$(err_msg)","short":false}]}]}"""
    _send_slack(payload)
end

# ----------------------------------------------------------------
# マクロ本体
# ----------------------------------------------------------------

"""
    @notify expr
    @notify label expr

式 `expr` を実行し、完了またはエラー時にSlack通知を送ります。

- 成功時: 経過時間つきで完了通知
- 失敗時: エラーメッセージを送信してから例外を再スロー

# 例
```julia
# シンプルな使い方
@notify simulate(model, 10_000)

# ラベルを付けると通知が分かりやすい
@notify "大規模シミュレーション" simulate(model, 10_000)

# begin...end ブロックにも使える
@notify "前処理+学習" begin
    X = preprocess(raw_data)
    train!(model, X, y)
end
```
"""
macro notify(args...)
    # 引数の解析: (label, expr) or (expr,)
    if length(args) == 1
        label = "Julia計算"
        expr  = args[1]
    elseif length(args) == 2
        label = args[1]   # 文字列リテラル or 変数
        expr  = args[2]
    else
        error("@notify の引数は1つか2つです: @notify [label] expr")
    end

    return quote
        local _label   = $(esc(label))
        local _t_start = time()
        local _result
        try
            _result = $(esc(expr))
            local _elapsed = time() - _t_start
            NotifyOnDone._notify_success(string(_label), _elapsed)
            _result          # 戻り値をそのまま返す
        catch _err
            local _elapsed = time() - _t_start
            NotifyOnDone._notify_error(string(_label), _elapsed, _err)
            rethrow()        # 元の例外を再スロー（JuliaのスタックトレースはそのままOK）
        end
    end
end

end # module
