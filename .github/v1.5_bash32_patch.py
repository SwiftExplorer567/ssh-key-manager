from pathlib import Path

p = Path('src/hosts.sh')
s = p.read_text()
old = '''    if (( refs > 0 )); then
        local -a kept_fps kept_hosts
        kept_fps=() kept_hosts=()
        for i in "${!POLICY_HOSTS[@]}"; do
            [[ "${POLICY_HOSTS[$i]}" == "$name" ]] && continue
            kept_fps+=("${POLICY_FINGERPRINTS[$i]}")
            kept_hosts+=("${POLICY_HOSTS[$i]}")
        done
        POLICY_FINGERPRINTS=("${kept_fps[@]}")
        POLICY_HOSTS=("${kept_hosts[@]}")
    fi
'''
new = '''    if (( refs > 0 )); then
        local -a kept_fps kept_hosts
        local kept_count=0
        kept_fps=() kept_hosts=()
        for i in "${!POLICY_HOSTS[@]}"; do
            [[ "${POLICY_HOSTS[$i]}" == "$name" ]] && continue
            kept_fps+=("${POLICY_FINGERPRINTS[$i]}")
            kept_hosts+=("${POLICY_HOSTS[$i]}")
            kept_count=$((kept_count + 1))
        done
        POLICY_FINGERPRINTS=()
        POLICY_HOSTS=()
        if (( kept_count > 0 )); then
            POLICY_FINGERPRINTS=("${kept_fps[@]}")
            POLICY_HOSTS=("${kept_hosts[@]}")
        fi
    fi
'''
if s.count(old) != 1:
    raise SystemExit(f'hosts empty-array block count={s.count(old)}')
p.write_text(s.replace(old, new, 1))

p = Path('src/fleet.sh')
s = p.read_text()
old = r'''json_findings_result() {
    local command_name="$1" rc="$2" source="$3" i first=1
    local -a codes messages
    local issues="" findings=""
    if [[ "$source" == "audit" ]]; then
        codes=("${AUDIT_FINDING_CODES[@]}")
        messages=("${AUDIT_FINDING_MESSAGES[@]}")
    else
        codes=("${POLICY_FINDING_CODES[@]}")
        messages=("${POLICY_FINDING_MESSAGES[@]}")
    fi
    for i in "${!messages[@]}"; do
        if (( first == 0 )); then
            issues="$issues,"
            findings="$findings,"
        fi
        issues="$issues\"$(json_escape "${messages[$i]}")\""
        findings="$findings{\"code\":\"$(json_escape "${codes[$i]}")\",\"severity\":\"warning\",\"message\":\"$(json_escape "${messages[$i]}")\"}"
        first=0
    done
    printf '{"command":"%s","version":"%s","ok":%s,"exit_code":%d,"issue_count":%d,"issues":[%s],"findings":[%s]}\n' \
        "$(json_escape "$command_name")" "$(json_escape "$VERSION")" \
        "$([[ "$rc" == "0" ]] && printf true || printf false)" "$rc" "${#messages[@]}" "$issues" "$findings"
}
'''
new = r'''json_findings_result() {
    local command_name="$1" rc="$2" source="$3" i first=1 issue_count=0
    local -a codes messages
    local issues="" findings=""
    codes=() messages=()
    if [[ "$source" == "audit" ]]; then
        issue_count="$AUDIT_ISSUES"
        if (( issue_count > 0 )); then
            codes=("${AUDIT_FINDING_CODES[@]}")
            messages=("${AUDIT_FINDING_MESSAGES[@]}")
        fi
    else
        issue_count="$POLICY_DRIFT"
        if (( issue_count > 0 )); then
            codes=("${POLICY_FINDING_CODES[@]}")
            messages=("${POLICY_FINDING_MESSAGES[@]}")
        fi
    fi
    if (( issue_count > 0 )); then
        for i in "${!messages[@]}"; do
            if (( first == 0 )); then
                issues="$issues,"
                findings="$findings,"
            fi
            issues="$issues\"$(json_escape "${messages[$i]}")\""
            findings="$findings{\"code\":\"$(json_escape "${codes[$i]}")\",\"severity\":\"warning\",\"message\":\"$(json_escape "${messages[$i]}")\"}"
            first=0
        done
    fi
    printf '{"command":"%s","version":"%s","ok":%s,"exit_code":%d,"issue_count":%d,"issues":[%s],"findings":[%s]}\n' \
        "$(json_escape "$command_name")" "$(json_escape "$VERSION")" \
        "$([[ "$rc" == "0" ]] && printf true || printf false)" "$rc" "$issue_count" "$issues" "$findings"
}
'''
if s.count(old) != 1:
    raise SystemExit(f'JSON renderer block count={s.count(old)}')
p.write_text(s.replace(old, new, 1))
