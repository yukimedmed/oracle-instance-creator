#!/bin/bash
#
# Oracle Cloud インスタンス作成スクリプト
# GitHub Actions から呼び出されることを想定
#

set -euo pipefail

# ===== 設定 =====

# インスタンスサイズの定義
declare -A SIZE_CONFIGS

# MAX: 4 OCPU / 24GB / 200GB（最大、確保しにくい）
SIZE_CONFIGS[MAX_OCPUS]=4
SIZE_CONFIGS[MAX_MEMORY]=24
SIZE_CONFIGS[MAX_BOOT_VOLUME]=200

# MID: 2 OCPU / 12GB / 100GB（中間、バランス型）
SIZE_CONFIGS[MID_OCPUS]=2
SIZE_CONFIGS[MID_MEMORY]=12
SIZE_CONFIGS[MID_BOOT_VOLUME]=100

# MIN: 1 OCPU / 6GB / 50GB（最小、確保しやすい）
SIZE_CONFIGS[MIN_OCPUS]=1
SIZE_CONFIGS[MIN_MEMORY]=6
SIZE_CONFIGS[MIN_BOOT_VOLUME]=50

# 環境変数から設定を取得
INSTANCE_SIZE="${INSTANCE_SIZE:-AUTO}"
COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-}"
SUBNET_ID="${OCI_SUBNET_ID:-}"
IMAGE_ID="${OCI_IMAGE_ID:-}"
AVAILABILITY_DOMAIN="${OCI_AVAILABILITY_DOMAIN:-}"
SSH_PUBLIC_KEY="${OCI_SSH_PUBLIC_KEY:-}"

# ===== イメージ自動取得関数 =====

get_latest_arm_image() {
    log_info "ARM用イメージを自動検索中..."

    # Oracle Linux 9 ARM イメージを検索
    local image_id
    image_id=$(oci compute image list \
        --compartment-id "$COMPARTMENT_ID" \
        --operating-system "Oracle Linux" \
        --operating-system-version "9" \
        --shape "VM.Standard.A1.Flex" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --limit 1 \
        --query 'data[0].id' \
        --raw-output 2>/dev/null) || true

    if [ -n "$image_id" ] && [ "$image_id" != "null" ]; then
        echo "$image_id"
        return 0
    fi

    # 別の方法: 全イメージから検索
    image_id=$(oci compute image list \
        --compartment-id "$COMPARTMENT_ID" \
        --all \
        --query "data[?contains(\"display-name\", 'Oracle-Linux-9') && contains(\"display-name\", 'aarch64')] | sort_by(@, &\"time-created\") | [-1].id" \
        --raw-output 2>/dev/null) || true

    if [ -n "$image_id" ] && [ "$image_id" != "null" ]; then
        echo "$image_id"
        return 0
    fi

    # それでも見つからない場合はUbuntuを試す
    image_id=$(oci compute image list \
        --compartment-id "$COMPARTMENT_ID" \
        --all \
        --query "data[?contains(\"display-name\", 'Canonical-Ubuntu') && contains(\"display-name\", 'aarch64')] | sort_by(@, &\"time-created\") | [-1].id" \
        --raw-output 2>/dev/null) || true

    if [ -n "$image_id" ] && [ "$image_id" != "null" ]; then
        echo "$image_id"
        return 0
    fi

    return 1
}

# インスタンス名（タイムスタンプ付き）
INSTANCE_NAME="free-tier-instance-$(date +%Y%m%d-%H%M%S)"

# ===== 関数定義 =====

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 必須環境変数のチェック
check_required_vars() {
    local missing=()

    [ -z "$COMPARTMENT_ID" ] && missing+=("OCI_COMPARTMENT_ID")
    [ -z "$SUBNET_ID" ] && missing+=("OCI_SUBNET_ID")
    [ -z "$AVAILABILITY_DOMAIN" ] && missing+=("OCI_AVAILABILITY_DOMAIN")
    # IMAGE_IDは自動取得可能なので必須ではない

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "以下の環境変数が設定されていません: ${missing[*]}"
        log_error "GitHub Secretsの設定を確認してください。"
        exit 1
    fi

    # IMAGE_IDが未設定の場合は自動取得
    if [ -z "$IMAGE_ID" ]; then
        log_info "OCI_IMAGE_IDが未設定のため、自動取得します..."
        IMAGE_ID=$(get_latest_arm_image)
        if [ -z "$IMAGE_ID" ]; then
            log_error "ARM用イメージが見つかりませんでした"
            exit 1
        fi
        log_info "イメージID: $IMAGE_ID"
    fi
}

# インスタンス作成を試行
create_instance() {
    local ocpus=$1
    local memory=$2
    local boot_volume=$3
    local size_name=$4

    log_info "インスタンス作成を試行中: ${size_name} (${ocpus} OCPU / ${memory}GB RAM / ${boot_volume}GB Storage)"

    # SSH公開鍵の設定
    local ssh_key_option=""
    if [ -n "$SSH_PUBLIC_KEY" ]; then
        # SSH公開鍵をファイルに保存
        echo "$SSH_PUBLIC_KEY" > /tmp/ssh_authorized_keys
        ssh_key_option="--ssh-authorized-keys-file /tmp/ssh_authorized_keys"
    fi

    # インスタンス作成コマンド
    local result
    result=$(oci compute instance launch \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --shape "VM.Standard.A1.Flex" \
        --shape-config "{\"ocpus\": ${ocpus}, \"memoryInGBs\": ${memory}}" \
        --display-name "$INSTANCE_NAME" \
        --image-id "$IMAGE_ID" \
        --subnet-id "$SUBNET_ID" \
        --assign-public-ip true \
        --boot-volume-size-in-gbs "$boot_volume" \
        $ssh_key_option \
        --wait-for-state RUNNING \
        --wait-interval-seconds 30 \
        --max-wait-seconds 1800 \
        2>&1) || {
        local exit_code=$?

        # Out of capacity エラーのチェック
        if echo "$result" | grep -qi "out of.*capacity\|out of host capacity\|capacity.*not.*available\|InternalError\|LimitExceeded"; then
            log_warn "キャパシティ不足: $size_name"
            return 2  # Out of capacity
        fi

        # 認証エラーのチェック
        if echo "$result" | grep -qi "NotAuthenticated\|InvalidParameter.*key\|401"; then
            log_error "認証エラー: APIキーまたは設定を確認してください"
            echo "$result"
            return 3  # 認証エラー
        fi

        # リミットエラーのチェック
        if echo "$result" | grep -qi "LimitExceeded\|QuotaExceeded"; then
            log_error "リソースリミット超過: 無料枠の上限に達している可能性があります"
            echo "$result"
            return 4  # リミットエラー
        fi

        # その他のエラー
        log_error "インスタンス作成に失敗しました"
        echo "$result"
        return 1  # 一般エラー
    }

    # 成功
    log_info "インスタンス作成成功！"
    echo "$result" > /tmp/instance_info.json

    # インスタンスIDを取得
    local instance_id
    instance_id=$(echo "$result" | jq -r '.data.id')
    log_info "インスタンスID: $instance_id"

    # パブリックIPを取得（VNICから）
    sleep 10  # VNIC作成を待機
    get_public_ip "$instance_id"

    return 0
}

# パブリックIPアドレスを取得
get_public_ip() {
    local instance_id=$1

    log_info "パブリックIPを取得中..."

    # VNICアタッチメントを取得
    local vnic_attachments
    vnic_attachments=$(oci compute vnic-attachment list \
        --compartment-id "$COMPARTMENT_ID" \
        --instance-id "$instance_id" \
        --all 2>/dev/null)

    if [ -n "$vnic_attachments" ]; then
        local vnic_id
        vnic_id=$(echo "$vnic_attachments" | jq -r '.data[0]."vnic-id"')

        if [ -n "$vnic_id" ] && [ "$vnic_id" != "null" ]; then
            local vnic_info
            vnic_info=$(oci network vnic get --vnic-id "$vnic_id" 2>/dev/null)

            if [ -n "$vnic_info" ]; then
                local public_ip
                public_ip=$(echo "$vnic_info" | jq -r '.data."public-ip"')

                if [ -n "$public_ip" ] && [ "$public_ip" != "null" ]; then
                    log_info "パブリックIP: $public_ip"
                    echo "$public_ip" > /tmp/instance_public_ip.txt
                    return 0
                fi
            fi
        fi
    fi

    log_warn "パブリックIPの取得に失敗しました。Oracle Cloud Consoleで確認してください。"
    return 1
}

# AUTOモード: 段階的にスペックを下げて試行
auto_create_instance() {
    local sizes=("MAX" "MID" "MIN")
    local max_retries_per_size=3

    for size in "${sizes[@]}"; do
        log_info "===== ${size}サイズで試行開始 ====="

        local ocpus=${SIZE_CONFIGS[${size}_OCPUS]}
        local memory=${SIZE_CONFIGS[${size}_MEMORY]}
        local boot_volume=${SIZE_CONFIGS[${size}_BOOT_VOLUME]}

        for ((i=1; i<=max_retries_per_size; i++)); do
            log_info "試行 ${i}/${max_retries_per_size}"

            create_instance "$ocpus" "$memory" "$boot_volume" "$size"
            local result=$?

            case $result in
                0)
                    log_info "成功！インスタンスが作成されました（${size}サイズ）"
                    return 0
                    ;;
                2)
                    # Out of capacity - 次のサイズへ
                    log_warn "キャパシティ不足。次のサイズを試します..."
                    break
                    ;;
                3)
                    # 認証エラー - 即座に終了
                    log_error "認証エラーのため終了します"
                    return 1
                    ;;
                4)
                    # リミットエラー - 即座に終了
                    log_error "リソースリミット超過のため終了します"
                    return 1
                    ;;
                *)
                    # その他のエラー - リトライ
                    if [ $i -lt $max_retries_per_size ]; then
                        log_warn "エラーが発生しました。5秒後にリトライします..."
                        sleep 5
                    fi
                    ;;
            esac
        done
    done

    log_error "全てのサイズで失敗しました。次回のスケジュール実行を待ちます。"
    return 2  # Out of capacity として扱う
}

# 固定サイズでインスタンス作成
fixed_create_instance() {
    local size=$1

    if [ "$size" != "MAX" ] && [ "$size" != "MID" ] && [ "$size" != "MIN" ]; then
        log_error "無効なサイズ: $size (MAX, MID, MIN のいずれかを指定)"
        return 1
    fi

    local ocpus=${SIZE_CONFIGS[${size}_OCPUS]}
    local memory=${SIZE_CONFIGS[${size}_MEMORY]}
    local boot_volume=${SIZE_CONFIGS[${size}_BOOT_VOLUME]}

    log_info "===== ${size}サイズ（固定）で作成 ====="
    create_instance "$ocpus" "$memory" "$boot_volume" "$size"
    return $?
}

# ===== メイン処理 =====

main() {
    log_info "===== Oracle Cloud インスタンス作成スクリプト開始 ====="
    log_info "インスタンスサイズモード: $INSTANCE_SIZE"

    # 必須環境変数のチェック
    check_required_vars

    # OCI CLIの確認
    if ! command -v oci &> /dev/null; then
        log_error "OCI CLIがインストールされていません"
        exit 1
    fi

    # インスタンス作成
    case "$INSTANCE_SIZE" in
        AUTO)
            auto_create_instance
            ;;
        MAX|MID|MIN)
            fixed_create_instance "$INSTANCE_SIZE"
            ;;
        *)
            log_error "無効なINSTANCE_SIZE: $INSTANCE_SIZE"
            log_error "AUTO, MAX, MID, MIN のいずれかを指定してください"
            exit 1
            ;;
    esac

    local result=$?

    log_info "===== スクリプト終了 ====="
    exit $result
}

# スクリプト実行
main "$@"
