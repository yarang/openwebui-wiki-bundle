# 제3자 고지

## anthropics/skills

- 출처: https://github.com/anthropics/skills (commit `2c5958ecac7cee2b583967a2c4981d0f4a75c579`)
- 라이선스: Apache License 2.0 — 전문은 [licenses/anthropics-skills-LICENSE.txt](licenses/anthropics-skills-LICENSE.txt)
- 쓴 곳: `guardian/claude-kit/skills/docx`, `xlsx`, `pptx` 의 `*_tool.py` 와 `SKILL.md`
- 쓴 방식: 코드는 가져오지 않았습니다. 그 저장소의 docx·xlsx·pptx skill 지침 가운데 작은 로컬 모델에 맞는 작성 규칙만 골라
  우리 도구의 동작과 짧은 SKILL.md 문장으로 다시 썼습니다.
  - docx: A4 쪽, DXA 단위 표 폭, 머리 행 반복·음영, `* `·`• ` 글머리를 진짜 목록으로, 자리 표시 경고
  - xlsx: 글꼴 통일, 합계 수식에 표시 형식, 계산값 대신 수식, 새 함수(XLOOKUP 등) 경고, 자리 표시 경고
  - pptx: 글자 크기 명시, `* `·`• ` 글머리, 글머리·표 넘침 경고, 자리 표시 경고

## python-hwpx

- 출처: https://github.com/airmang/python-hwpx (버전 6.11.0)
- 라이선스: Apache License 2.0 (휠 메타데이터 `License-Expression: Apache-2.0`)
- 쓴 곳: `guardian/claude-kit/wheels/python_hwpx-6.11.0-py3-none-any.whl` — 수정하지 않고 그대로 동봉합니다. `install-claude-code.sh`가 이 휠을 `~/.claude/skills/hwpx/lib/`에 풉니다.
- 라이선스 전문과 원저작자의 NOTICE는 휠 안 `python_hwpx-6.11.0.dist-info/licenses/`의 `LICENSE`·`NOTICE`에 들어 있습니다.
