# RepoPocket 项目约定

## 修改代码与新增功能

- 本项目的代码修复、调整和后续新增功能统一使用“修改代码”对应的 Ponytail 技能，默认 full 级别；用户指定的级别优先。
- 先确认相关调用链与影响范围，优先复用项目现有组件、共享逻辑及平台能力，完成最小且完整的改动。
- 新功能应接入现有的账号隔离、权限判断、导航、分页和操作生命周期；根据实际影响检查相关入口。
- 界面沿用现有 `SoftGroupRows`、`softGroupedRow` 和 `SoftGroupShape` 的圆角、分隔线及间距。
- 按改动风险执行必要验证；明确区分静态检查、原生编译测试与 iPhone 实机验证。
- 用户只要求想法或估算时，先给方案；确定实施范围后再开发。

<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->
