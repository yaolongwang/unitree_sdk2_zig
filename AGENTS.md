# Repository guidance

- 遵循 ASD-STE100 规则，达到至少 80% 相似度（包括文档和代码注释）。
- 落库文档使用声明式表达，禁止写实施步骤、验收清单、工作进度等过程内容。
- 临时文件放入 `tmp/` 文件夹。
- 提交信息使用简短的中文 Conventional Commits（`<type>[scope]: <描述>`）。
- 提交前运行 `zig fmt --check`。
