# Changelog

## [0.4.5](https://github.com/avante-corp/avante.nvim/compare/v0.4.4...v0.4.5) (2026-10-23)


### Continuous Integration

* restore missing version from rockspec ([6155a52](https://github.com/avante-corp/avante.nvim/commit/6155a52516bfa7bec3ac383d89af1f5d63b9e877))

## [0.4.4](https://github.com/avante-corp/avante.nvim/compare/v0.4.3...v0.4.4) (2026-10-23)


### Continuous Integration

* trigger luarocks action ([1f90c3b](https://github.com/avante-corp/avante.nvim/commit/1f90c3b5e1c6b23c74b540540dfa255ebaf29005))

## [0.4.3](https://github.com/avante-corp/avante.nvim/compare/v0.4.2...v0.4.3) (2026-10-20)


### Continuous Integration

* dont chaincall luarocks-upload ([bcbe3b1](https://github.com/avante-corp/avante.nvim/commit/bcbe3b145620e7cf21219ca2d02bb6f2a99de600))

## [0.4.2](https://github.com/avante-corp/avante.nvim/compare/v0.4.0...v0.4.2) (2026-10-19)


### ⚠ BREAKING CHANGES

* dont include out of cwd templates

### Features

* **acp:** add :Avante acp sessions to list and resume agent sessions ([99ee143](https://github.com/avante-corp/avante.nvim/commit/99ee14397d2106e7ec6494dc579797127d3367e3))
* Add support for gpt 6 model family ([8e54c3f](https://github.com/avante-corp/avante.nvim/commit/8e54c3f15f262c5c423c21f83d8675781d909254))
* **AvanteSwitchProvider:** accepter filters ([1edd5e5](https://github.com/avante-corp/avante.nvim/commit/1edd5e5bfc0b3c1bfe7f1001888729df2ac359cc))
* dont include out of cwd templates ([1b19261](https://github.com/avante-corp/avante.nvim/commit/1b1926138fdda7d4ef4bb4398cafb9ac1df1b96a))
* label ACP providers in switch selector ([a75581d](https://github.com/avante-corp/avante.nvim/commit/a75581d539258eae783e7924255064e83efcc669))
* Show acp mode header info ([162c0b6](https://github.com/avante-corp/avante.nvim/commit/162c0b6eb23b783965ffbc946710cb0e3a86a677))
* **sidebar:** focus the input when pressing i in the result window ([7f3fbf9](https://github.com/avante-corp/avante.nvim/commit/7f3fbf9576f21d67a903b470160b506206dbb0e2))
* **web_search:** add Firecrawl search engine ([fc82420](https://github.com/avante-corp/avante.nvim/commit/fc82420b9c6935c8d78e13e01d3deb59fef3188c))
* **web_search:** add Serply search engine ([86d5740](https://github.com/avante-corp/avante.nvim/commit/86d5740beb8b66381799b76ba1d3766cedc5c16c))
* **zen:** accept prompt on cli ([1f90503](https://github.com/avante-corp/avante.nvim/commit/1f9050390c4d80afdcd36ce07466f915efe67685))


### Bug Fixes

* **acp:** align initialization and capabilities with ACP v1 ([bf7507e](https://github.com/avante-corp/avante.nvim/commit/bf7507ecf3d034dfbed0916159ea5987ab38561f))
* **acp:** align session setup and lifecycle with ACP v1 ([ea24ed7](https://github.com/avante-corp/avante.nvim/commit/ea24ed772ac8d27bcbe464d13946cf598c445e03))
* **acp:** declare _replayed on BaseSessionUpdate for typecheck ([cc8d467](https://github.com/avante-corp/avante.nvim/commit/cc8d4677f23aa7f76d477d254a76a7cacfb7edf7))
* **acp:** don't replay previous session when opening a new chat ([664d298](https://github.com/avante-corp/avante.nvim/commit/664d29844e3643c31cd9c21958833c00ca662bbf))
* **acp:** hardcode version info until version is managed automatically ([6c9fdf7](https://github.com/avante-corp/avante.nvim/commit/6c9fdf7c92a9ea93409208972991ce265ec574d3))
* **acp:** ignore replayed session/load updates ([317b026](https://github.com/avante-corp/avante.nvim/commit/317b026e4c88f4b100cac5a8e1b8854825053bea))
* **acp:** never send an empty prompt array for the edit flow ([b4cc3c9](https://github.com/avante-corp/avante.nvim/commit/b4cc3c90ce96ec9ca54790c0e5e4afde78abda69))
* **acp:** recover Codex stale sessions ([2fd012c](https://github.com/avante-corp/avante.nvim/commit/2fd012c107ce98d87195f231a6df3c1b34b92925))
* **acp:** switch history before opening sidebar in select_history ([e4f0a7b](https://github.com/avante-corp/avante.nvim/commit/e4f0a7b5f5b389458b4d7f5a54a1f38bd80bc5b7))
* fix switches between acp and provider ([2cfb470](https://github.com/avante-corp/avante.nvim/commit/2cfb4704a7c897a9cc57705be1bb02211f74e409))
* **history:** don't write a new chat to disk until it's used ([8b38e85](https://github.com/avante-corp/avante.nvim/commit/8b38e8575d0310bd3f584e49c4d7edca507355f8))
* **history:** preserve valid timestamps when loading ([c1157be](https://github.com/avante-corp/avante.nvim/commit/c1157befe66a72acac8665a0c4ee9cdccd1cff43))
* **llm:** address review feedback ([16dc348](https://github.com/avante-corp/avante.nvim/commit/16dc3484395f2f8f2658d2b8e6aedfc56dd9b17e))
* **llm:** keep API keys off curl's command line ([efb9798](https://github.com/avante-corp/avante.nvim/commit/efb979853cdea9bca7f75080bb6d5a6c859c57ab))
* **log:** build reverse log level lookup without mutating the iterated table ([a5cb87b](https://github.com/avante-corp/avante.nvim/commit/a5cb87bddec4e60941fe7cfd700f1451896d1c93))
* **lua_ls:** could not find plenary.Path ([2cab1e1](https://github.com/avante-corp/avante.nvim/commit/2cab1e14c9eb9501d0e10537e80c9ba8d471ba98))
* **openai:** improve GPT-5/GPT-6 Responses routing and preserve finalized reasoning state ([faf1ae6](https://github.com/avante-corp/avante.nvim/commit/faf1ae68271f0402f9ac6fc6897f26d112e3ac34))
* **openai:** preserve Responses API phases and skip legacy role padding ([bdffd74](https://github.com/avante-corp/avante.nvim/commit/bdffd74056f40bb6c9aea95d993b6e68a3788650))
* prevent provider and model switches during generation ([ba86bb1](https://github.com/avante-corp/avante.nvim/commit/ba86bb14fc35f7705c19622771bfae7ee5f01925))
* remove default result header title ([9f13c15](https://github.com/avante-corp/avante.nvim/commit/9f13c158447da06a703b4fb3ee5d8e782b8bf3bb))
* set execute bit on contrib/avante ([3053d7a](https://github.com/avante-corp/avante.nvim/commit/3053d7abc160e3d318e9737e8c10e72b3c2521b6))
* simplify ACP session not found matching ([52b5457](https://github.com/avante-corp/avante.nvim/commit/52b5457ff36f5c6d92528d30c2785ccd5a0fe4d0))
* **test:** now are now using vim.schedule for the response so let's wait for result to ([4eb9c1f](https://github.com/avante-corp/avante.nvim/commit/4eb9c1f35ddaec22eee40072b92be448311a1fe3))
* use revision as version ([68ff1c4](https://github.com/avante-corp/avante.nvim/commit/68ff1c460237f711a84828b1978522414f6de455))
* **web_search:** call on_complete outside the fast event context ([a22876b](https://github.com/avante-corp/avante.nvim/commit/a22876b1181b7de02cc108f177158aad41a6f3ca))


### Continuous Integration

* build before creating release ([3123c27](https://github.com/avante-corp/avante.nvim/commit/3123c27075ff2377526fe3a9d4076da83847486e))
* fix target-branch  ([4682f81](https://github.com/avante-corp/avante.nvim/commit/4682f810716dc297ca0fea1038692a8db65d68c1))
