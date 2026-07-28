#!/bin/zsh

set -euo pipefail

repo_dir="${0:A:h:h}"
test_root="$(mktemp -d /private/tmp/email-time-repair-test.XXXXXX)"
trap 'rm -rf "$test_root"' EXIT

source_mbox="$test_root/source.mbox"
output_dir="$test_root/output"

mkdir -p "$output_dir"

printf '%s\n' \
  'From - Fri Aug 20 03:43:05 2010' \
  'From: sender@example.com' \
  'Subject: Recoverable date' \
  'Date: Fri, 01 Jan 2101 00:00:00 +0000' \
  'X-MailStore-Date: 20100820034305' \
  '' \
  'First message.' \
  '' \
  'From - Sat Jan 01 00:00:00 2000' \
  'From: sender@example.com' \
  'Subject: Missing stored date' \
  'Date: Fri, 01 Jan 2101 00:00:00 +0000' \
  '' \
  'Second message.' \
  '' \
  'From - Sat Jan 01 00:00:00 2000' \
  'Malformed message without a header-body separator' \
  > "$source_mbox"

EML_NO_OPEN=1 "$repo_dir/Email Time Repair.command" \
  "$source_mbox" \
  "$output_dir" \
  "2000-01-01 12:00:00" \
  </dev/null

grep -q '成功修复：1 封' "$output_dir/修复结果.txt"
grep -q '已设为自定义时间：1 封' "$output_dir/修复结果.txt"
grep -q '处理失败但已原样保留：1 封' "$output_dir/修复结果.txt"

test "$(grep -c '^From ' "$output_dir/01-修复成功.mbox")" -eq 1
test "$(grep -c '^From ' \
  "$output_dir/02-缺少原日期-已设为自定义时间.mbox")" -eq 1
test "$(grep -c '^From ' \
  "$output_dir/03-修复失败-原样保留.mbox")" -eq 1

grep -q '^Date: Fri, 20 Aug 2010 03:43:05 +0000$' \
  "$output_dir/01-修复成功.mbox"
grep -q '^Date: Sat, 01 Jan 2000 12:00:00 ' \
  "$output_dir/02-缺少原日期-已设为自定义时间.mbox"

echo "All tests passed."
