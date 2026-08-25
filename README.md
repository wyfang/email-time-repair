# Email Time Repair

在 macOS 本地修复 Thunderbird 导出邮件的错误日期，并生成可重新导入的分类 MBOX。

## 功能

- 处理单个 MBOX 或包含 `.eml` 的文件夹
- 从 `X-MailStore-Date` 恢复标准邮件日期与 MBOX 内部日期
- 修复部分旧邮件中未经 MIME 编码的中文发件人和主题
- 为缺少原始日期的邮件设置统一时间
- 不修改输入文件，结果写入新的时间戳目录
- 全程本地处理，不连接邮箱或上传邮件

## 使用

需要 macOS、Python 3、Thunderbird 与 [ImportExportTools NG](https://addons.thunderbird.net/thunderbird/addon/importexporttools-ng/)。

1. 在 Thunderbird 的“本地文件夹 → 磁盘空间”中选择“不删除任何消息”，避免旧日期邮件导入后被自动清理。
2. 将目标文件夹导出为 MBOX；导出 EML 时选择“消息（嵌入附件）”，不要使用可能破坏旧中文内容的 v15 格式。
3. 双击 `Email Time Repair.command`，选择输入并填写缺失日期，例如 `2000-01-01 00:00:00`。
4. 检查输出报告，再分别导入生成的 MBOX。

首次运行可按住 Control 点击脚本并选择“打开”。无法执行时运行：

```zsh
chmod +x "/你的路径/Email Time Repair.command"
```

## 输出

```text
日期已修复-YYYYMMDD-HHMMSS/
├── 01-修复成功.mbox
├── 02-缺少原日期-已设为自定义时间.mbox
├── 03-修复失败-原样保留.mbox
└── 修复结果.txt
```

存在 `X-MailStore-Date` 时按 UTC 解析；缺少时按 Mac 当前时区使用自定义时间；处理失败的邮件会原样进入失败分类。

## 命令行与测试

```zsh
"./Email Time Repair.command" \
  "/path/to/source.mbox" \
  "/path/to/output-folder" \
  "2000-01-01 00:00:00"

./tests/test.sh
```

请先备份原始邮件，并在删除任何内容前核对数量、日期、主题与附件。公开报告问题时不要提交真实邮件、地址、正文或附件。

## 版权说明

原创代码依据 [MIT License](./LICENSE) 发布。个人数据和素材不在许可范围内。
