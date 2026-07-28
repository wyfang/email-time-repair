#!/bin/zsh

# 从 X-MailStore-Date 恢复 Date 与 Thunderbird MBOX 内部时间。

set -u

if (( $# > 0 )); then
  input_dir="$1"
else
  input_type="$(osascript -e '
    button returned of (display dialog "请选择要处理的输入类型" ¬
      with title "修复邮件日期" ¬
      buttons {"取消", "EML 文件夹", "MBOX 文件"} ¬
      default button "MBOX 文件" ¬
      cancel button "取消")
  ')" || exit 1

  if [[ "$input_type" == "MBOX 文件" ]]; then
    input_dir="$(osascript -e '
      POSIX path of (choose file with prompt "请选择要修复的 MBOX 文件")
    ')" || exit 1
  else
    input_dir="$(osascript -e '
      POSIX path of (choose folder with prompt "请选择包含 EML 邮件的文件夹")
    ')" || exit 1
  fi
fi

input_dir="${input_dir%/}"
if [[ ! -d "$input_dir" && ! -f "$input_dir" ]]; then
  echo "找不到文件夹或 MBOX 文件：$input_dir"
  read "?按回车键关闭……"
  exit 1
fi

if (( $# > 2 )); then
  fallback_date="$3"
elif (( $# == 0 )); then
  fallback_date="$(osascript -e '
    text returned of (display dialog ¬
      "请输入缺少原始日期的邮件要统一使用的时间：\n格式：年-月-日 时:分:秒\n时间按照 Mac 当前时区解释。" ¬
      with title "设置缺少日期邮件的时间" ¬
      default answer "2000-01-01 00:00:00" ¬
      buttons {"取消", "继续"} ¬
      default button "继续" ¬
      cancel button "取消")
  ')" || exit 1
else
  fallback_date="2000-01-01 00:00:00"
fi

stamp="$(date '+%Y%m%d-%H%M%S')"
if (( $# > 1 )); then
  output_dir="$2"
else
  output_dir="${input_dir:h}/日期已修复-${stamp}"
fi
mkdir -p "$output_dir"

/usr/bin/python3 - "$input_dir" "$output_dir" "$fallback_date" <<'PY'
from __future__ import annotations

import re
import os
import sys
from datetime import datetime, timezone
from email.header import Header
from email.utils import format_datetime
from email.utils import formataddr, parseaddr
from pathlib import Path


source = Path(sys.argv[1])
destination = Path(sys.argv[2])
fallback_date_text = sys.argv[3]
try:
    fallback_instant = datetime.strptime(
        fallback_date_text, "%Y-%m-%d %H:%M:%S"
    ).replace(tzinfo=datetime.now().astimezone().tzinfo)
except ValueError:
    raise SystemExit(
        "自定义时间格式错误，请使用：年-月-日 时:分:秒"
        "（例如 2000-01-01 12:00:00）"
    )
date_source_pattern = re.compile(
    br"(?im)^X-MailStore-Date:[ \t]*(\d{14})[ \t]*\r?$"
)
standard_date_pattern = re.compile(
    br"(?im)^Date:[^\r\n]*(?:\r?\n[ \t][^\r\n]*)*"
)
mozilla_header_pattern = re.compile(
    br"(?im)^X-Mozilla-(?:Status2?|Keys):[^\r\n]*"
    br"(?:\r?\n[ \t][^\r\n]*)*\r?\n?"
)
mbox_from_pattern = re.compile(br"(?m)^(>*From )")
mbox_separator_pattern = re.compile(br"(?m)^From [^\r\n]*\r?\n")


def normalize_legacy_header(header: bytes, field_name: bytes) -> bytes:
    pattern = re.compile(
        br"(?im)^" + re.escape(field_name)
        + br":[^\r\n]*(?:\r?\n[ \t][^\r\n]*)*"
    )
    match = pattern.search(header)
    if not match:
        return header

    field = match.group(0)
    _, raw_value = field.split(b":", 1)
    raw_value = re.sub(br"\r?\n[ \t]+", b" ", raw_value).strip()
    if not any(byte >= 128 for byte in raw_value):
        return header

    try:
        decoded = raw_value.decode("utf-8")
    except UnicodeDecodeError:
        try:
            decoded = raw_value.decode("gb18030")
        except UnicodeDecodeError:
            return header

    if "\ufffd" in decoded:
        return header

    if field_name.lower() == b"from":
        display_name, address = parseaddr(decoded)
        if address and address.isascii():
            encoded_value = formataddr((display_name, address), charset="utf-8")
        else:
            # Some old messages contain only a raw Chinese sender name, with
            # no address at all. Encode the complete value as a MIME header.
            encoded_value = Header(
                decoded, "utf-8", header_name="From"
            ).encode()
    else:
        encoded_value = Header(
            decoded, "utf-8", header_name=field_name.decode("ascii")
        ).encode()

    try:
        encoded_bytes = encoded_value.encode("ascii")
    except UnicodeEncodeError:
        encoded_bytes = Header(
            decoded,
            "utf-8",
            header_name=field_name.decode("ascii"),
        ).encode().encode("ascii")
    replacement = field_name + b": " + encoded_bytes
    return header[:match.start()] + replacement + header[match.end():]


def prepare_mbox_message(raw_message: bytes) -> bytes:
    separator = b"\r\n\r\n" if b"\r\n\r\n" in raw_message else b"\n\n"
    if separator in raw_message:
        original_header, original_body = raw_message.split(separator, 1)
        original_header = mozilla_header_pattern.sub(b"", original_header)
        result = original_header + separator + original_body
    else:
        result = raw_message
    result = result.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    return mbox_from_pattern.sub(br">\1", result)


def envelope_datetime(separator_line: bytes) -> datetime:
    text = separator_line.decode("ascii", errors="replace")
    match = re.search(
        r"\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) "
        r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) "
        r"\d{1,2} \d{2}:\d{2}:\d{2} \d{4}\b",
        text,
    )
    if match:
        return datetime.strptime(
            match.group(0), "%a %b %d %H:%M:%S %Y"
        ).replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc)


fixed = 0
skipped = 0
failed: list[tuple[str, str]] = []
category_names = {
    "fixed": "01-修复成功",
    "skipped": "02-缺少原日期-已设为自定义时间",
    "failed": "03-修复失败-原样保留",
}
mbox_messages: dict[str, list[tuple[datetime, bytes]]] = {
    key: [] for key in category_names
}
category_directories = {
    key: destination / name for key, name in category_names.items()
}

if source.is_dir():
    source_items = [
        (eml_path.name, eml_path.read_bytes(), None)
        for eml_path in sorted(source.glob("*.eml"))
    ]
    write_individual_eml = True
else:
    source_mbox = source.read_bytes()
    separator_matches = list(mbox_separator_pattern.finditer(source_mbox))
    source_items = []
    for index, match in enumerate(separator_matches, start=1):
        end = (
            separator_matches[index].start()
            if index < len(separator_matches)
            else len(source_mbox)
        )
        chunk = source_mbox[match.end():end]
        raw_message = (
            re.sub(br"(?m)^>(>*From )", br"\1", chunk).rstrip(b"\r\n")
            + b"\r\n"
        )
        source_items.append(
            (
                f"message-{index:06d}.eml",
                raw_message,
                envelope_datetime(match.group(0)),
            )
        )
    write_individual_eml = False

if write_individual_eml:
    for category_directory in category_directories.values():
        category_directory.mkdir(parents=True, exist_ok=True)

for source_name, raw, original_instant in source_items:
    try:
        separator = b"\r\n\r\n" if b"\r\n\r\n" in raw else b"\n\n"
        if separator not in raw:
            raise ValueError("找不到邮件头与正文的分隔位置")

        header, body = raw.split(separator, 1)
        source_match = date_source_pattern.search(header)
        if not source_match:
            skipped += 1
            header = normalize_legacy_header(header, b"From")
            header = normalize_legacy_header(header, b"Subject")
            newline = b"\r\n" if b"\r\n" in header else b"\n"
            date_line = (
                "Date: " + format_datetime(fallback_instant)
            ).encode("ascii")
            if standard_date_pattern.search(header):
                header = standard_date_pattern.sub(
                    date_line, header, count=1
                )
            else:
                header = header + newline + date_line
            corrected_message = header + separator + body
            if write_individual_eml:
                output_path = (
                    category_directories["skipped"] / source_name
                )
                output_path.write_bytes(corrected_message)
                timestamp = fallback_instant.timestamp()
                os.utime(output_path, (timestamp, timestamp))
            mbox_messages["skipped"].append(
                (
                    fallback_instant,
                    prepare_mbox_message(corrected_message),
                )
            )
            continue

        header = normalize_legacy_header(header, b"From")
        header = normalize_legacy_header(header, b"Subject")
        stored = source_match.group(1).decode("ascii")
        instant = datetime.strptime(stored, "%Y%m%d%H%M%S").replace(
            tzinfo=timezone.utc
        )
        date_line = ("Date: " + format_datetime(instant)).encode("ascii")
        newline = b"\r\n" if b"\r\n" in header else b"\n"

        if standard_date_pattern.search(header):
            header = standard_date_pattern.sub(date_line, header, count=1)
        else:
            header = header + newline + date_line

        if write_individual_eml:
            output_path = category_directories["fixed"] / source_name
            corrected_message = header + separator + body
            output_path.write_bytes(corrected_message)
            timestamp = instant.timestamp()
            os.utime(output_path, (timestamp, timestamp))
        mbox_message = prepare_mbox_message(header + separator + body)
        mbox_messages["fixed"].append((instant, mbox_message))
        fixed += 1
    except Exception as exc:
        failed.append((source_name, str(exc)))
        if write_individual_eml:
            (
                category_directories["failed"] / source_name
            ).write_bytes(raw)
        mbox_messages["failed"].append(
            (
                original_instant or datetime.now(timezone.utc),
                prepare_mbox_message(raw),
            )
        )

summary = destination / "修复结果.txt"
weekdays = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
months = (
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
)
for category_key, messages in mbox_messages.items():
    category_name = category_names[category_key]
    mbox_path = destination / f"{category_name}.mbox"
    with mbox_path.open("wb") as mbox_file:
        for instant, message in messages:
            envelope_date = (
                f"{weekdays[instant.weekday()]} "
                f"{months[instant.month - 1]} "
                f"{instant.day:02d} {instant:%H:%M:%S %Y}"
            )
            mbox_file.write(f"From - {envelope_date}\n".encode("ascii"))
            mbox_file.write(b"X-Mozilla-Status: 0001\n")
            mbox_file.write(b"X-Mozilla-Status2: 00000000\n")
            mbox_file.write(b"X-Mozilla-Keys:                 \n")
            mbox_file.write(message.rstrip(b"\n") + b"\n\n")

with summary.open("w", encoding="utf-8") as report:
    report.write(f"成功修复：{fixed} 封\n")
    if write_individual_eml:
        report.write(
            f"缺少 X-MailStore-Date、已设为自定义时间：{skipped} 封\n"
        )
        report.write(f"处理失败：{len(failed)} 封\n")
    else:
        report.write(
            f"缺少 X-MailStore-Date、已设为自定义时间：{skipped} 封\n"
        )
        report.write(f"处理失败但已原样保留：{len(failed)} 封\n")
    report.write(f"使用的自定义时间：{fallback_date_text}（Mac 当前时区）\n")
    report.write("请在 Thunderbird 中分别导入以下 MBOX：\n")
    for category_key, category_name in category_names.items():
        report.write(
            f"- {category_name}.mbox"
            f"（{len(mbox_messages[category_key])} 封）\n"
        )
    for filename, reason in failed:
        report.write(f"- {filename}: {reason}\n")

print(f"成功修复：{fixed} 封")
if write_individual_eml:
    print(f"已设为自定义时间：{skipped} 封")
    print(f"失败：{len(failed)} 封")
else:
    print(f"已设为自定义时间：{skipped} 封")
    print(f"失败但已原样保留：{len(failed)} 封")
PY

exit_code=$?
if (( exit_code == 0 )); then
  echo
  echo "完成。原文件没有被修改。"
  echo "修复后的邮件位于："
  echo "$output_dir"
  if [[ "${EML_NO_OPEN:-0}" != "1" ]]; then
    open "$output_dir"
  fi
else
  echo
  echo "处理过程中出现错误，原文件没有被修改。"
fi

read "?按回车键关闭……"
exit $exit_code
