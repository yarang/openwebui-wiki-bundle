# claude-lms 문서·이미지 Skill 설계안

상태: **hwpx·docx·xlsx·pptx skill 구현 완료** (image 계획) · 작성 2026-11-04 · 갱신 2026-11-10

claude-lms(오프라인 Claude Code + LM Studio `gemma-4-e4b-it-mlx`, 컨텍스트 65536)에서
HWPX·Word·Excel 문서 작업과 이미지 처리를 할 수 있도록 Claude Code skill 4종을 추가한다.

- 실행 흐름: [diagrams/claude-lms-skills-runtime.mmd](../diagrams/claude-lms-skills-runtime.mmd) · [svg](../diagrams/claude-lms-skills-runtime.svg)
- 설치 흐름(설계 목표, docx·xlsx·image 포함): [diagrams/claude-lms-skills-install.mmd](../diagrams/claude-lms-skills-install.mmd) · [svg](../diagrams/claude-lms-skills-install.svg). 지금 구현된 hwpx 설치 흐름은 [diagrams/claude-lms-install-flow.svg](../diagrams/claude-lms-install-flow.svg)

> 이 문서는 설계 초안이다. 구현된 오피스 skill(docx·xlsx·pptx)의 실제 모습은 [CLAUDE-LMS-MANUAL.md §11](../CLAUDE-LMS-MANUAL.md#11-오피스-skill-docx--xlsx--pptx)에 적었다.

## 1. 설계 원칙

| 원칙 | 이유 |
|---|---|
| **스크립트 우선** — 모델은 CLI 한 줄만 호출하고, 결과로 파일 경로와 요약 한 줄을 받는다. OWPML/OOXML XML을 모델이 직접 쓰지 않는다. | 4B급 로컬 모델은 긴 XML을 정확히 생성하지 못한다. 결정적 코드가 형식을 책임진다. |
| **짧은 skill** — description은 한 줄(한국어), SKILL.md 본문은 1k 토큰 미만. 세부 옵션은 `--help`로 위임한다. | 시험 Mac(M1) 측정치로 prefill이 약 4초/1k 토큰이다(22k 토큰 89초). 상시 주입되는 description과 호출 때마다 들어가는 본문이 그대로 지연이 된다. |
| **`/이름` 호출을 기본 경로로** — "hwpx skill로 …"처럼 이름을 말하는 요청을 보조 경로로 둔다. description만 보고 자동 선택하는 것에는 기대지 않는다. | 시험 Mac spike(§6.1) 결과, `/ping`과 이름을 말한 요청은 성공했고 설명 매칭만으로는 0/2였다. |
| **원본 불변** — 항상 새 파일로 쓰고, 저장 직후 검증한다. | 양식 채우기나 수정 중 원본이 손상되는 것을 막는다. |
| **완전 오프라인** — `pip --no-index`만 쓰고, 첫 실행 때 모델을 내려받는 라이브러리는 기본 경로에서 쓰지 않는다. | 번들 원칙(외부 접속 0건)을 지킨다. |

## 2. 런타임 확인 결과

skill 스크립트는 `~/.guardian-llm/venv/bin/python`(Python 3.12)으로 실행한다.
이 venv는 guardian `install.sh`가 `pip install --no-index … open-webui mcpo`로 만든 것이다.
아래 라이브러리는 모두 **open-webui가 버전을 고정한 직접 의존성**이라 별도 설치 없이 들어 있다.
(확인 근거: open_webui-0.12.3 METADATA, 번들 20261027T130325Z `wheels/`)

| 라이브러리 | 버전 | 용도 |
|---|---|---|
| python-docx | 1.2.0 | docx 읽기·쓰기 |
| openpyxl | 3.1.5 | xlsx 읽기·쓰기·서식 |
| python-pptx | 1.0.2 | pptx(선택) |
| pandas | 3.0.3 | csv/xlsx 변환·집계 |
| pypdf | 6.7.5 | PDF 텍스트 추출(보조) |
| lxml | 6.1.1 | python-hwpx 의존성 |
| Pillow | 12.3.0 | 이미지 변환·크롭·회전·압축 |
| opencv-python-headless | 4.13.0.92 | 스캔 보정(기울기·이진화·원근) |
| rapidocr / onnxruntime | 3.10.0 / 1.26.0 | OCR 보조 경로 — **아래 주의** |

**번들에 없는 것과 대응**

- **python-hwpx 6.11.0** (Apache-2.0, 순수 파이썬, 의존성은 `lxml>=4.9,<7`뿐)
  - 번들 Python과 lxml 6.1.1로 `--no-index` 설치를 시험했고 성공했다.
  - 문단과 표(2×2)를 생성 → 저장 → 재열기 → `export_markdown`까지 정상 동작했다.
  - `hwpx-validate` 결과는 "All schema validations passed"였다.
  - 공유 venv에는 넣지 않고 **skill 전용 `lib/`에 vendoring**한다(§4).
  - 이렇게 하면 Open WebUI venv와 `wiki-layer-lib.sh`를 건드리지 않아도 된다.
- **vision-ocr** (`openwebui/ocr/vision-ocr`, arm64 Mach-O, macOS Vision 기반, 한국어 지원)
  - 현재 번들 `tools/`에는 `python`과 `uv`만 있어 대상 Mac에 배포되지 않는다.
  - claude kit에 동봉해야 한다.
- **rapidocr 주의**
  - 휠 안에 det·rec·cls 모델이 들어 있어 오프라인으로 실행된다.
  - 그러나 기본 인식 모델 `PP-OCRv6_rec_small`(multi)의 지원 언어 목록에 **한국어가 없다**.
  - 따라서 rapidocr는 영문·숫자 전용 **저하 폴백**으로만 쓴다.
  - 한국어 OCR은 vision-ocr만 담당한다.
- **sips**는 macOS 기본 탑재라 HEIC 변환, 크기 조정, 형식 변환에 바로 쓴다.

## 3. Skill 구성

| skill | description (상시 주입, 한 줄) | 하위 명령 |
|---|---|---|
| `hwpx` | 한글(HWPX/HWP) 문서 읽기·만들기·양식 채우기 | `read`, `from-md`, `fill`, `fields`, `validate` |
| `docx` | Word(docx) 문서 읽기·만들기·양식 채우기 | `read`, `from-md`, `fill` |
| `xlsx` | Excel(xlsx) 읽기·표 만들기·서식·수식 | `read`, `from-csv`, `from-md`, `style` |
| `image` | 이미지 변환·크기조정·스캔 보정·OCR | `info`, `convert`, `resize`, `crop`, `rotate`, `scan`, `ocr`, `compress` |
| `pptx` | 발표자료(pptx) 만들기 | `from-md` |

> 표의 하위 명령은 설계안이다. 구현된 docx·xlsx·pptx 명령은 `from-md`·`read`뿐이다. `fill`(docx), `from-csv`·`style`(xlsx)은 설계만 있고 구현하지 않았다. `image`는 아직 계획이다. 실제 구현은 [CLAUDE-LMS-MANUAL.md §11](../CLAUDE-LMS-MANUAL.md#11-오피스-skill-docx--xlsx--pptx)을 본다.

### 3.1 hwpx

- `read <파일> [--md]`: 본문과 표를 Markdown으로 출력한다(`export_markdown`).
  - 출력이 길면 앞부분만 보여 주고, 전체는 `<파일>.hwpx.md`로 저장한다.
- `from-md <in.md> <out.hwpx>`: 다음 Markdown 요소를 HWPX로 바꾼다.
  - 제목(`#`)
  - 개조식 부호(□·ㅇ·-)
  - 표
  - 굵게
- `fields <양식.hwpx>`: 채울 수 있는 칸을 출력한다.
  - 대상: 누름틀 필드, 라벨 옆 표 셀
  - 사용 API: `list_form_fields`, `get_table_map`, `find_cell_by_label`
  - 채울 수 없는 누름틀은 `(fill 불가: 사유)`로 미리 표시한다. 사유는 다음과 같다.
    - `같은 이름의 누름틀이 여러 개`
    - `누름틀 끝 표시가 없음`
    - `다른 누름틀과 구간이 겹쳐 채울 수 없음`
    - `다른 누름틀 X 안에 있음` / `다른 누름틀 X 를 품고 있음`(중첩. 끝 없는 누름틀의 시작이 구간 안에 있어도 품은 것으로 본다)
    - 이름이 빈 누름틀은 X 자리에 `(이름 없음)`이 들어간다.
  - 누름틀 시작·끝의 짝은 python-hwpx와 같다: 각 시작은 자기 **뒤에** 처음 나오는 같은 id의 끝과 짝을 이룬다. id가 중복되어도 이 규칙대로 짝짓는다(같은 끝을 두 시작이 함께 가리킬 수 있다). 시작보다 앞에 있는 떠도는 끝은 무시한다.
  - 표 칸은 **위치 키**로 나온다(2026-11-09, §6.4): `- 성명 (표 0, 행 7) ← 책임자 / 사업 책임자 (PM)`.
    - 키는 `라벨 (표 N, 행 M)`이다. 같은 표·같은 행에 같은 라벨이 둘 이상이면 `, 열 C`를 붙인다.
    - ` ← ` 뒤는 그 칸이 어느 묶음인지 알려 주는 문맥이다(위쪽 병합 칸, 앞 문단 제목). 문맥이 없으면 ` ← `를 붙이지 않는다.
    - 같은 라벨이 문서에 여럿이면 칸 안 줄바꿈을 공백 한 칸으로 줄인다(`주요\n내용` → `주요 내용`).
    - 숫자·기호뿐인 칸은 라벨로 보지 않는다. 병합이 겹친 표는 건너뛰고 알린다.
  - `read`는 병합이 겹친 표를 만나도 죽지 않고 그 표만 글자로 풀어 쓴다.
- `fill <양식.hwpx> <값.json> <out.hwpx>`: 칸을 채워 **새 파일**로 저장한다.
  - 사용 API: `fill_form_field`, `fill_by_path`
  - 하나라도 못 채우면 출력 파일을 만들지 않고 한 줄로 끝낸다.
    - 형식: `ERROR 채우지 못한 키: A(사유); 요청한 키(B)를 채우면 다른 누름틀이 바뀜: C(사유)`
    - 앞 묶음은 요청한 키 자신의 사유, 뒤 묶음은 요청하지 않은 누름틀(또는 같은 이름의 다른 누름틀)이 손상되는 경우다.
  - 채우기 전후 불변식: 요청하지 않은 누름틀의 값·시작·끝 표시(끝 없는 누름틀의 시작 포함)가 바뀌면 `ERROR`로 막는다. 사전 판정이 놓친 경우의 마지막 방어선이다.
  - 키는 위치 키, 라벨 이름, 누름틀 이름 중 하나다. `fields` 줄을 통째로 붙여도 ` ← ` 뒤와 `(fill 불가: …)`를 떼고 읽는다.
    - 라벨 이름이 여러 칸이면 `같은 라벨이 여러 칸: 전화 (표 0, 행 1), 전화 (표 0, 행 3) 중 하나를 키로 쓰세요`로 거부한다.
  - **다시 시도할 키**: 사유가 정확히 `라벨 없음`인 키에는 같은 줄 끝에 `; 다시 시도할 키: <키> → <위치 키>`를 붙인다.
    - 예: `ERROR 채우지 못한 키: 사업책임자(PM) 성명(라벨 없음); 다시 시도할 키: 사업책임자(PM) 성명 → 성명 (표 0, 행 7)`
    - 후보: 라벨 글자(공백 제거)가 키에 들어 있는 표 자리. 키에서 라벨을 뺀 나머지를 그 자리 문맥과 견주어, **가장 길게 맞은** 자리만 남긴다. 맞는 자리가 없으면 후보 전부(최대 6개, ` 또는 `으로 잇고 넘으면 ` 외 N개`). 후보가 없으면 `→ 없음(fields 줄의 키를 그대로 복사)`.
    - 자동으로 채우지 않는다. 고친 키로 다시 부르는 것은 모델 몫이다(`SKILL.md` 마지막 규칙).
  - **값.json 중괄호 누락**: 바깥 `{ }`를 빼먹은 `"키": "값",` 줄만 있는 파일은 `{` + 글 + `}`로 한 번 더 읽어 객체면 그대로 쓴다(같은 키·값 형식 검사는 그대로, 빈 파일은 제외). 그래도 못 읽으면 `JSON 파싱 실패: <경로> (…); JSON 은 { 로 시작해 } 로 끝나야 하고 마지막 값 뒤에는 쉼표를 쓰지 않습니다`.
- `validate <파일>`: `hwpx-validate`와 같은 스키마 검증을 한다. 쓰기 명령은 모두 마지막에 자동으로 실행한다.
- `.hwp` 5.x 처리
  - python-hwpx 6.11에는 `hwpx.hwp5` 모듈(HWP 5.0 ↔ OWPML 변환)이 들어 있다. 이를 이용해 `read`가 `.hwp`도 받도록 한다.
  - 실제 `.hwp` 샘플로는 **아직 검증하지 않았다**(§6).
  - 읽기에 실패하면 모델이 해석을 즉흥으로 시도하지 않게 한다. 대신 스크립트가 다음 안내를 출력한다: "한글에서 *다른 이름으로 저장 → HWPX* 후 다시 시도".
  - 형식 판별은 확장자와 magic bytes로 한다(HWP는 OLE CFB, HWPX는 ZIP).

### 3.2 docx

> 설계 당시 안이다. 구현은 `from-md`·`read`만 있고, `document_generator.py` 재사용(doclib)과 `fill`은 하지 않았다. [MANUAL §11](../CLAUDE-LMS-MANUAL.md#11-오피스-skill-docx--xlsx--pptx) 참고.

- `from-md`는 기존 [document_generator.py](../../open-webui-tools/document_generator.py)의 Markdown→docx 변환과 `document-templates/theme-*.docx` 테마를 **재사용**한다.
  - 이를 위해 Open WebUI Tool 클래스에서 변환 핵심을 import 가능한 모듈로 분리한다.
  - 분리한 모듈은 `~/.local/share/claude-lms/lib/doclib/`에 둔다.
  - Open WebUI 쪽 Tool도 같은 모듈을 쓰도록 맞추는 것은 별도 작업으로 둔다.
- `fill`은 `{{키}}` 자리표시자를 치환한다. run이 여러 개로 쪼개진 경우에도 처리한다.

### 3.3 xlsx

> 설계 당시 안이다. 구현은 `from-md`·`read`만 있고, `from-csv`·`--sum`·`style`은 하지 않았다. [MANUAL §11](../CLAUDE-LMS-MANUAL.md#11-오피스-skill-docx--xlsx--pptx) 참고.

- `from-csv`와 `from-md`(Markdown 표)는 다음 서식을 적용한다.
  - 머리행 굵게
  - 열 너비 자동
  - 숫자 서식
  - 틀 고정
- `--sum` 옵션은 합계 행을 **수식**(`=SUM(...)`)으로 넣는다.
- `read`는 시트 목록과 각 시트 상위 N행을 Markdown 표로 출력한다.

### 3.4 image

| 명령 | 구현 |
|---|---|
| `convert`, `resize` | `sips` 우선(HEIC 포함), 실패하면 Pillow |
| `crop`, `rotate`, `compress` | Pillow |
| `scan` | OpenCV: 그레이 → 기울기 보정 → 적응형 이진화 (문서 사진 → 스캔본) |
| `ocr` | vision-ocr(한국어). 없으면 rapidocr(영문·숫자 전용임을 출력에 명시) |

## 4. 디렉터리와 배포

```
guardian/claude-kit/                 # install-claude-code.sh 가 복사할 원본
  skills/
    hwpx/  SKILL.md  scripts/hwpx  scripts/hwpx_tool.py  scripts/skill-guard  scripts/skill_guard.py  lib/hwpx_fields.py  lib/hwpx_slots.py
    docx/  SKILL.md  scripts/docx  scripts/docx_tool.py
    xlsx/  SKILL.md  scripts/xlsx  scripts/xlsx_tool.py
    pptx/  SKILL.md  scripts/pptx  scripts/pptx_tool.py
  wheels/python_hwpx-6.11.0-py3-none-any.whl
  tests/  accept_hwpx.sh  accept_docx.sh  accept_xlsx.sh  accept_pptx.sh  accept_skill_guard.sh  lib_office_accept.sh
```

아직 없는 것(계획): `skills/image/`(§3.4), `lib/doclib/`(§3.2), `bin/vision-ocr`(§2). `NOTICE` 파일도 두지 않았다 — 고지는 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)가 맡는다(§8).

설치 위치:

- `~/.claude/skills/<name>/`: 사용자 범위라 claude-lms를 어느 폴더에서 열든 보인다.
- `~/.claude/skills/hwpx/lib/`: `install-claude-code.sh`가 python-hwpx 휠을 `unzip -qo`로 풀어 넣는다(2026-11-09 구현. pip를 쓰지 않음). 절차는 [CLAUDE-LMS-MANUAL.md §2.3](../CLAUDE-LMS-MANUAL.md#23-hwpx-skill-설치).
  - 같은 폴더에 `hwpx_fields.py`(누름틀 분석 모듈)도 복사한다. `hwpx_tool.py`가 `../lib`를 sys.path에 넣고 import한다. 없으면 `ERROR hwpx skill 설치가 불완전합니다(lib/hwpx_fields.py 없음)`로 끝난다.
- `~/.local/share/claude-lms/lib/` *(계획 — 아직 설치하지 않는다)*: doclib과 테마.
- `~/.local/share/claude-lms/bin/vision-ocr` *(계획 — 아직 설치하지 않는다)*: 복사 후 `xattr -dr com.apple.quarantine`을 실행한다.

스크립트 규칙:

- `scripts/<name>`은 bash 래퍼다.
  - 실행 순서: `~/.guardian-llm/venv/bin/python`이 있는지 점검 → `exec "$PY" -I <tool>.py "$@"`.
  - `-I`는 `PYTHONPATH`와 스크립트 디렉터리를 무시한다. 그래서 `<tool>.py`가 `lib/`와 doclib 경로를 `sys.path`에 직접 넣는다.
- SKILL.md는 `~/.claude/skills/<name>/scripts/<name>` **절대 경로**로 호출을 안내한다.
  - `${CLAUDE_SKILL_DIR}` 같은 치환 변수는 2.1.321 시점에도 확인되지 않아 쓰지 않는다.
- 출력 규약
  - 성공: stdout 첫 줄이 `OK <출력경로>`, 둘째 줄 이후가 짧은 요약이다.
  - 실패: `ERROR <사유>` 한 줄과 함께 exit 코드 1 이상으로 끝난다.
  - 모델이 결과를 오해할 여지를 줄이기 위한 규약이다.
- 위 Python이 없을 때(kit만 따로 복사한 Mac)
  - `install-claude-code.sh`는 skill 설치를 건너뛰고 경고만 출력한다.
  - claude-lms 설치 자체는 계속 진행한다.

## 5. SKILL.md 형태 (예: hwpx)

실제 파일은 [guardian/claude-kit/skills/hwpx/SKILL.md](../../guardian/claude-kit/skills/hwpx/SKILL.md)이다. 2026-11-09 보강판(§6.3, §6.4)이며, 작은 모델이 실수할 단계를 줄이도록 썼다.

- 명령은 매번 전체 경로로 쓴다. 셸 변수(`H=`·`$H`)는 Bash 호출 사이에 남지 않는다.
- Markdown 저장과 `from-md`를 Bash **한 번**에 묶은 예시를 준다. 예시 안 줄은 들여쓰지 않는다(들여쓴 `EOF`는 heredoc을 끝내지 못한다).
- 작업 파일은 `./이름`으로 현재 폴더에 만든다. skill의 Base directory에는 쓰지 않는다.
- 첫 줄은 명령형으로 "지금 바로 Bash 도구로 실행해 파일을 만든다, '이해했습니다' 같은 글 답으로 끝내지 않는다, Skill을 다시 부르지 않는다"이다(2026-11-11, §6.8).
- `from-md`는 md 경로 하나만 쓴다. 출력은 같은 이름의 `.hwpx`다(§6.8).
- 양식 채우기(실제 양식 검증 후, §6.4): 키를 지어내지 말고 `fields` 줄의 키를 복사하며, `ERROR`에 `다시 시도할 키`가 있으면 키를 바꿔 `fill`을 한 번 더 부른다.

````markdown
---
name: hwpx
description: 한글(HWPX/HWP) 문서 읽기·만들기·양식 채우기
---
이 안내를 읽었으면 지금 바로 Bash 도구로 아래 명령을 실행해 파일을 만든다. '이해했습니다' 같은 글 답으로 끝내지 않고, Skill 을 다시 부르지 않는다.
한글 문서 작업은 아래 명령만 쓴다. XML을 직접 만들지 않는다.
명령은 매번 전체 경로 ~/.claude/skills/hwpx/scripts/hwpx 로 쓴다. H= 정의나 $H 는 쓰지 않는다.
작업 파일(md·json)과 결과 파일은 현재 작업 폴더에 ./이름 으로 만든다. skill 의 Base directory 는 명령이 있는 곳일 뿐이며 거기에는 아무것도 쓰지 않는다. Markdown 저장에 Write 도구를 쓰지 말고 Bash heredoc 을 쓴다.
새로 쓰기: Bash 한 번에 저장과 변환을 함께 한다.

```bash
cat > ./주간보고.md <<'EOF'
# 주간 보고
이번 주 진행 사항.
EOF
~/.claude/skills/hwpx/scripts/hwpx from-md ./주간보고.md
```

from-md 에는 md 경로 하나만 쓴다. 결과는 같은 이름의 .hwpx 파일로 생긴다(./주간보고.md → ./주간보고.hwpx).
읽기: ~/.claude/skills/hwpx/scripts/hwpx read ./파일.hwpx
양식: ~/.claude/skills/hwpx/scripts/hwpx fields ./양식.hwpx → 값을 ./값.json 에 저장(Bash heredoc) → ~/.claude/skills/hwpx/scripts/hwpx fill ./양식.hwpx ./값.json ./결과.hwpx
JSON 키는 fields 줄에서 '- ' 뒤부터 ' ← ' 앞까지를 그대로 복사한다(예: 성명 (표 0, 행 7)). ← 뒤는 그 칸이 어느 항목인지 알려 주는 설명이다.
사용자 말로 키를 지어내지 말고 fields 를 먼저 실행해, 사용자가 말한 항목을 ← 뒤 설명과 맞춰 그 줄의 키를 쓴다.
값은 문자열(정수 가능)로 쓰고, 'fill 불가' 가 붙은 줄은 넣지 않는다.
양식이 길면 fields 를 한 번만 실행하고 필요한 줄만 골라 쓴다.
출력 파일이 이미 있으면 거부되므로 다른 이름을 쓴다.
결과 첫 줄이 OK 면 그 경로를 사용자에게 알린다. ERROR 에 '다시 시도할 키' 가 있으면 ./값.json 의 그 키를 → 뒤 위치 키로 바꿔 저장하고 fill 을 다시 실행한다(출력 파일 이름은 새로). 그래도 ERROR 면 사유를 사용자에게 알린다.
자세한 옵션: ~/.claude/skills/hwpx/scripts/hwpx --help
````

## 6. 미검증 사항과 검증 계획

| # | 항목 | 방법 | 막는 범위 |
|---|---|---|---|
| 1 | ~~gemma가 skill을 호출하는가~~ → **완료(§6.1)** | 시험 Mac `~/bundles/skill-spike-20261104T0859Z` | — |
| 2 | `.hwp` 5.x 읽기 | 실제 `.hwp` 샘플로 `read` | §3.1의 `.hwp` 경로 |
| 3 | python-hwpx 출력을 한글 뷰어에서 여는가 | HOP(hop-viewer 꾸러미)으로 열기. HOP은 rhwp 엔진이므로 최종 확인은 현장 PC의 한글에서 | `from-md`와 `fill` 결과 품질 |
| 4 | vision-ocr 서명과 Gatekeeper | 깨끗한 시험 Mac에서 quarantine 제거 후 첫 실행 | `image ocr` |
| 5 | skill 본문 토큰과 지연 | spike에서 prefill 시간 측정 | §1 크기 기준 |

### 6.1 skill 호출 spike 결과 (2026-11-04, 시험 Mac)

시험 환경

| 항목 | 값 |
|---|---|
| 하드웨어 | 시험 Mac (M1 16GB) |
| 모델 | gemma-4-e4b-it-mlx, 컨텍스트 65536 |
| 실행 | Claude Code 2.1.316, `claude-lms -p … --allowedTools Bash,Skill` |
| skill | 프로젝트 범위 `ping` (스크립트가 `OK PONG-7319`를 출력하고 `calls.log`에 기록) |

| 시험 | 요청 | 결과 | 경로 | 시간 |
|---|---|---|---|---|
| A | "핑 시험 해줘" (description 매칭만) | **실패 2/2** — skill도 Bash도 호출하지 않음 | — | 23–82초 (첫 회는 모델 로드 13.6초 포함) |
| B | `/ping` | **성공** — 출력 `OK PONG-7319 시험` | 본문 주입 → Bash, 2턴 | 11초 |
| C | "ping skill을 사용해서 핑 시험 해줘" | **성공** | Skill 도구 → Bash | 12초 |

결론과 반영 사항

- 이름 없이 설명만 맞춘 요청으로는 gemma가 skill을 고르지 않는다. 사용자 안내와 SKILL.md는 `/hwpx …`를 기본으로 하고, "hwpx skill로 …"를 대안으로 적는다.
  - 사용자 범위 `~/.claude/CLAUDE.md`에 "한글 문서 → hwpx skill" 같은 짧은 대응표를 넣으면 자동 선택이 나아질 수 있다. 다만 아직 시험하지 않았다.
- 시스템 프롬프트(첫 요청 입력 10,146 토큰)는 LM Studio 프롬프트 캐시가 재사용했다. 이어진 요청은 `cache_read`가 20k–30k 토큰이었다.
  - 그래서 skill 호출 한 번은 10초대로 끝났다.
- **별도 결함**: A의 최종 답변 텍스트에 gemma의 사고 채널 토큰 `<|channel>thought …`가 그대로 섞여 나왔다.
  - 사용자에게 사고 과정이 노출된다.
  - LM Studio의 gemma-4 reasoning 분리 설정, 또는 claude-lms 쪽 처리를 별도로 조사해야 한다.
- 시험 방법 주의: `claude -p`는 stdin을 프롬프트 뒤에 붙인다. ssh heredoc 안에서 실행하면 남은 줄이 프롬프트로 들어가므로 `< /dev/null`이 필요하다.

### 6.2 설치 후 end-to-end 확인 (2026-11-09, 시험 Mac·운영 Mac)

`install-claude-code.sh`로 설치한 뒤 `claude-lms -p '/hwpx 회의록.md 파일에 … 저장한 다음, from-md 회의록.md 회의록.hwpx 를 실행해서 …' --allowedTools Bash,Write,Read`로 확인했다. 첫 회는 `Skill`도 허용했다.

| 기계 | 결과 | 관찰 |
|---|---|---|
| 운영 Mac (`google/gemma-4-e4b`, 2.1.317) | **성공 1/1** (135초, 프롬프트 ③) | md 저장 → `from-md` → `OK`, validate OK |
| 시험 Mac (`gemma-4-e4b-it-mlx`, 2.1.319) | **실패 3/3** (프롬프트 ①②③ 각 1회) | ① `Skill(hwpx)` 재호출 반복으로 600초 초과. ② `new`·인수 하나짜리 `from-md` 등 CLI 오용. ③ 아래 |

두 기계를 같은 조건으로 비교한 것은 프롬프트 ③뿐이다(1/1 대 0/1). 모델 빌드와 Claude Code 버전이 서로 달라서, 차이의 원인(모델 빌드·CLI 버전·우연)은 아직 분리하지 못했다.

③의 세션 기록:

1. `from-md 회의록.md`처럼 출력 경로를 빠뜨렸다.
2. `Write`로 `~/.claude/skills/hwpx/회의록.md`에 쓰려 했다. skill 기준 폴더를 작업 폴더로 착각한 것이다. `~/.claude` 아래라 권한 거부로 막혔다.
3. 작업 폴더에서 `from-md`를 돌려 `ERROR 파일 없음`이 났다.

이 실패를 바탕으로 SKILL.md를 보강했다(§5, §6.3).

### 6.3 SKILL.md 보강 후 재시험 (2026-11-09)

보강 내용(zai GLM `glm-5.3` 작성, 검토·재현은 Claude):

- 명령을 매번 전체 경로 `~/.claude/skills/hwpx/scripts/hwpx`로 쓴다. `H=`·`$H`는 없앴다.
- Markdown 저장(heredoc)과 `from-md ./a.md ./a.hwpx`를 Bash 한 번에 묶은 예시를 넣었다.
- 작업 파일은 현재 폴더 `./이름`에 만들고, skill Base directory에는 쓰지 않으며, Markdown 저장에 Write를 쓰지 않는다.
- 안내를 읽은 뒤 Skill을 다시 부르지 않는다.

같은 기계·같은 모델·같은 CLI에서 설치만 다시 하고(이전 skill은 `~/.claude/skills-backup/`으로 이동) 같은 프롬프트로 돌렸다.

| 기계 | 프롬프트 | 보강 전 | 보강 후 | 시간 |
|---|---|---|---|---|
| 시험 Mac (`gemma-4-e4b-it-mlx`, 2.1.319) | ③ 단계 명시, Skill 금지 | 0/1 | **3/3** | 90·128·156초 |
| 시험 Mac | ① `/hwpx` + Skill 허용 | 0/1 (600초 초과) | **2/2** | 67·66초 |
| 운영 Mac (`google/gemma-4-e4b`, 2.1.317) | ③ (회귀 확인) | 1/1 | **1/1** | 75초 |

- 모든 실행에서 validate OK, 내용 일치. 세션 기록에 `Skill` 재호출·Write·인수 하나짜리 `from-md`가 없었다.
- gemma는 예시를 거의 그대로 따랐다. 5회 중 3회는 저장과 변환을 Bash 한 번에, 2회는 두 번에 나눠 했다.
- ①에서는 본문을 `**참석자:** 3명` / `**안건:** 예산 검토` 두 줄로 바꿔 썼다. 요청 내용은 모두 들어갔다.
- 표본이 작다(시험 Mac 5회). "해결"이 아니라 "이 조건에서 5/5"로 본다. ② Skill 금지 + 단계 미명시 프롬프트는 다시 돌리지 않았다.

### 6.4 실제 한/글 양식 검증 (2026-11-09)

공공기관 실제 양식 3종(사업계획서 양식, 제안서, 계획서)으로 `fields`·`fill`·`read`를 확인하고, gemma-4-e4b(context 65536)로 end-to-end를 돌렸다. **실제 양식 파일은 저장소·시험에 넣지 않는다.** 시험은 같은 모양을 흉내 낸 합성 양식(`tests/accept_hwpx.sh` §100–§102)으로만 한다.

**도구 단독(모델 없이) 문제와 수정** — 구현 zai GLM `glm-5.3`, 시험 작성·검토·재현 Claude:

| 문제 | 관찰 | 수정 |
|---|---|---|
| A. 같은 라벨 여러 칸 | 사업계획서 `fields` 76줄 중 61줄이 `fill 불가: 같은 라벨이 여러 칸`(성명·전화·이메일이 묶음·표마다 반복) | fix1: 위치 키 `라벨 (표 N, 행 M[, 열 C])` + ` ← 문맥`(위쪽 병합 칸, 표 앞 문단) |
| B. `read` 중단 | 제안서에서 `ValueError: overlapping cell spans`로 내부 오류 | fix1: 겹친 병합 표는 글자만 풀어 쓰고 계속 |
| C. 잡음 라벨 | `1`, `0,000,000` 같은 숫자·기호 칸이 라벨로 나와 context 낭비 | fix1: 목록에서 빼고 개수만 한 줄로 |
| E. 말없는 건너뜀 | 병합이 겹친 표를 `fields`가 조용히 빠뜨림 | fix1: 건너뛴다고 알림 |
| F. 지어낸 키 | gemma가 `fields`를 안 보고 사용자 말(`사업책임자(PM) 성명`)을 키로 써서 `라벨 없음`으로 포기(6/6) | fix2: `다시 시도할 키` 힌트, 빈 ` ← ` 꼬리 제거, 칸 안 줄바꿈을 공백 한 칸으로, SKILL.md 재시도 규칙 |
| G. 힌트 두 갈래 | 바깥 병합 칸 `책임자`가 두 묶음을 덮어 힌트가 `행 7 또는 행 10` | fix3: 문맥 점수(가장 길게 맞은 자리만) |
| H. 중괄호 누락 | gemma가 값.json 바깥 `{ }`를 빼먹어 `Extra data`로 실패(시험 Mac f1-a, f2-c) | fix4: `{…}`로 감싸 한 번 더 읽기, 실패 시 고치는 법 한 조각 |
| D. 글 속 빈칸 | `(   )년`처럼 문단 안 빈칸은 칸이 아니라 라벨로 잡히지 않음 | **미해결**(한계로 문서화) |

**end-to-end smoke**(`/hwpx 양식.hwpx 를 채워서 …` 한 번, 600초 감시, 시나리오 f2 = 묶음별 같은 라벨 `성명` 둘을 채움, f1 = 단순 라벨 3개, r1 = 제안서 읽고 요약):

| 회차 | 기계 | f2 (같은 라벨, 3회) | f1 | r1 |
|---|---|---|---|---|
| fix1 후 (realform2) | 시험 Mac | 0/3 (지어낸 키 → `라벨 없음` 포기) | 1/1 | 1/1 |
| | 운영 Mac | 0/3 (같은 원인) | 1/1 | 1/1 |
| fix3 후 (realform3) | 시험 Mac | **2/3** (실패 1: Skill 재호출 루프로 600초 초과) | 0/1 (중괄호 누락 → 포기) | 1/1 |
| | 운영 Mac | **3/3** | 1/1 | 1/1 |

- f2 성공 5회 중 3회는 처음에 키를 지어냈다가 `다시 시도할 키`를 보고 위치 키로 고쳐 다시 `fill`해 성공했다. 2회는 처음부터 `fields` 줄을 복사했다. 1회는 ` ← 문맥`까지 붙인 키를 썼는데 fill이 ` ← ` 뒤를 버리므로 그대로 성공했다(시험 100e가 이 동작을 고정한다).
- 성공한 모든 결과에서 validate OK, 홍길동·김철수가 각 묶음의 `성명` 칸에 들어갔다. 2회는 첫 결과 이름이 이미 있어서 `결과_v2.hwpx`·`결과_2.hwpx`로 저장했다(SKILL.md 규칙대로).
- **fix4(중괄호)는 재현으로 확인**: 시험 Mac f1-a가 실제로 쓴 값.json과 f2-c의 첫 값.json을 그대로 새 `fill`에 넣어 각각 `OK`(3칸·4칸, 검증 통과). 모델 재실행은 하지 않았다.
- **context**: 세션 최대 입력 토큰 22,337–31,180(65,536의 34–48%). `fields` 한 번이 약 10k 토큰이라 SKILL.md에 "fields 를 한 번만 실행하고 필요한 줄만" 규칙을 두었다.
- **시간**: 운영 Mac의 경과 시간(1,091–9,210초)은 비교 지표로 쓰지 않는다. 세션 기록에 `Connection lost while your computer was asleep` API 오류가 회차마다 1–9번 있었고, pmset에도 Sleep/Wake가 남았다. 시스템 잠자기가 시간을 늘린 것이며 모델 폭주가 아니다. 다음 원격 시험은 `caffeinate -i`로 감싼다.
- **남은 한계**
  - Skill 재호출 루프(시험 Mac f2-b, 이번 회차 10회 중 1회): gemma가 `Skill(hwpx, args="fields …")`를 69번 반복하고(세션 기록의 Skill tool_use 수) Bash로 넘어가지 않았다. SKILL.md 6행이 이미 금지하므로 도구로는 못 막는다. → §6.5 skill-guard hook으로 대응.
  - D(글 속 빈칸)는 `fill` 대상이 아니다. 이런 양식은 `read` 후 사람이 채우거나 별도 기능이 필요하다.
  - 표본이 작다(기계마다 f2 3회). "해결"이 아니라 "이 조건에서 f2 5/6"로 본다.
- 인수 시험: 403 PASS / 0 FAIL(`accept_hwpx.sh` sha256 `8cdfa5dd…`).

### 6.5 skill-guard PreToolUse hook (2026-11-09)

§6.4의 Skill 재호출 루프(gemma가 `Skill(hwpx, args="fields …")`를 69번 반복)를 막는 hook. `Skill`은 SKILL.md를 대화에 싣기만 하고 실행은 하지 않는데, gemma는 실행된다고 믿는다. 그래서 같은 세션에서 같은 skill의 두 번째 호출부터는 거부하고, 거부 이유에 Bash로 실행할 명령을 넣는다. 사용법·조건은 [CLAUDE-LMS-MANUAL.md §3.4](../CLAUDE-LMS-MANUAL.md#34-skill-guard-hook), 흐름은 [diagrams/skill-guard-hook.mmd](../diagrams/skill-guard-hook.mmd).

- 구성: `skills/hwpx/scripts/skill-guard`(bash, 파이썬 찾기·5초 제한·언제나 종료 0) + `skill_guard.py`(판정). `claude-lms`가 `--settings '{"hooks":{"PreToolUse":[{"matcher":"Skill",…}]}}'`를 인수 맨 앞에 붙인다(2026-11-10부터 matcher `Skill|Write|Edit|MultiEdit|Bash`와 `Stop`도, §6.6). `~/.claude/settings.json`은 건드리지 않는다.
- 설계 원칙: **fail-open**. 입력·이름·상태 폴더가 이상하거나 파이썬이 없으면 출력 없이 허용한다. hook이 대화를 막는 쪽으로 고장 나면 안 되기 때문이다. 거부 이유에 옮겨 적는 args는 명령 모양(`^[a-z][a-z-]*` 첫 낱말)·300자 이하·셸 특수 문자 없음일 때만 쓰고, 아니면 `--help`를 안내한다(모델이 그대로 붙여 넣어도 안전하도록).
- 구현 zai GLM `glm-5.3`(한 번에 시험 통과), 시험 작성·검토·재현 Claude.

**시험 Mac 확인**(Claude Code 2.1.319, gemma-4-e4b-it-mlx, 새 묶음 폴더):

| 확인 | 결과 |
|---|---|
| `--settings` hook이 붙는가 | 붙음. 강제로 Skill을 부르게 한 probe에서 상태 폴더(700)·세션 파일(600, 내용 `hwpx`)이 생겼고 세션 id가 transcript와 같음 |
| 사용자 hook과 병합되는가 | 병합됨. 같은 `PreToolUse:Skill`에 시험 Mac 사용자 설정의 기존 hook도 함께 실행됨 |
| 거부 이유가 모델에 가는가 | 감. `--session-id`로 세션을 정하고 상태 파일에 `hwpx`를 미리 적은 probe에서 도구 결과가 `PreToolUse:Skill hook error: hwpx 안내는 이미 읽었습니다. Skill 을 다시 부르지 말고 Bash 로 실행하세요: ~/.claude/skills/hwpx/scripts/hwpx fields ./양식.hwpx` |
| 모델이 따르는가 | 따름(1/1). 바로 다음 차례에 그 명령을 Bash로 그대로 호출(probe는 Skill만 허용해서 승인 대기로 끝남) |
| f2 smoke 3회 | 1/3 성공. 세 번 모두 Skill 재호출이 없어 hook은 실행되지 않음. 실패 2회는 `다시 시도할 키` 힌트를 받고도 키를 고치지 않고 포기·반복(hook과 무관, §6.4 F 계열) |

**운영 Mac 확인**(2026-11-10, 패키지 설치. Claude Code 2.1.317 → 2.1.321, gemma-4-e4b, 새 묶음 폴더 `~/bundles/claude-code-kitinstall-20261110T0057Z`):

| 확인 | 결과 |
|---|---|
| 패키지 설치 | 묶음 `.tar.gz.sha256`·내부 `SHA256SUMS` 12개 모두 OK, `install-claude-code.sh` 종료 0. 2.1.317은 `~/.local/share/claude/versions/`에 남음 |
| 설치 파일이 저장소와 같은가 | 같음. `claude-lms`·`skill-guard`·`skill_guard.py`·`hwpx` sha256이 저장소·시험 Mac과 일치 |
| `--settings` hook이 붙는가 | 붙음. 실행 중인 claude 명령줄에 hook JSON이 보이고, probe 세션 파일(600, 내용 `hwpx`)이 상태 폴더(700)에 생김 |
| 거부 이유가 모델에 가는가 | 감. 도구 결과가 시험 Mac과 같은 `PreToolUse:Skill hook error: hwpx 안내는 이미 읽었습니다. … Bash 로 실행하세요: ~/.claude/skills/hwpx/scripts/hwpx fields ./양식.hwpx` |
| 모델이 따르는가 | 따름(1/1). 바로 다음 차례에 그 명령을 Bash로 호출(Skill만 허용한 probe라 승인 대기로 끝남) |

- 운영 Mac은 `caffeinate -i`를 잡고 있어도 Maintenance Sleep에 들어가 첫 probe가 12분 넘게 멈췄다. `caffeinate -s -i`로 다시 돌리자 두 probe가 약 1분 만에 끝났다. 원격으로 오래 돌릴 때는 `-s`를 함께 쓴다.

- 사용자가 입력한 `/hwpx …`는 Skill 도구 호출이 아니라 프롬프트 펼침이라 hook을 거치지 않는다. 그래서 모델이 처음 스스로 부르는 `Skill(hwpx)`는 허용되고 그다음부터 거부된다.
- **알려진 한계**
  - 호출 **전에** 기록하므로 첫 Skill 호출이 권한 거부 등으로 실패해도 "읽음"으로 친다.
  - 자동 압축으로 SKILL.md가 사라진 뒤의 재호출도 거부된다. 거부 이유의 명령·`--help`가 덜어 주지만 fields → JSON → fill 순서까지 되살리지는 않는다.
  - args의 유니코드 제어 문자(U+2028, 양방향 표시 등)는 지우지 않는다(ASCII 제어 문자만 공백으로).
  - 잠금이 없다. 같은 세션에서 동시에 두 번 부르면 둘 다 허용될 수 있다(gemma는 도구를 하나씩 부르므로 실사용 영향 작음).
  - f2 표본은 3회, 거부 따름은 1회. "루프 해결"이 아니라 "거부가 전달되고 1/1 따랐다"로 본다.
- 인수 시험: `accept_skill_guard.sh` 30 PASS / 0 FAIL(sha256 `f73cdfac…`, 가짜 HOME·lms·claude로 돌아 LM Studio 불필요), `accept_hwpx.sh` 403 PASS 그대로.

### 6.6 오피스 파일 거부와 Stop 가드 (2026-11-10)

운영 Mac 실전 시험(오피스 kit, gemma-4-e4b)은 pptx 1/1, xlsx 1/3, docx 1/3이었다. 실패는 두 가지였다. 하나는 Markdown을 `Write`로 `회의록.docx`에 써 놓고 "만들었다"고 답한 것(Office가 못 여는 텍스트 파일). 다른 하나는 `Skill`로 SKILL.md를 읽은 뒤 "다음 작업을 지시해 주세요"라며 멈춘 것이다. §6.5 hook을 넓혀 둘 다 막는다. 사용법은 [CLAUDE-LMS-MANUAL.md §3.4](../CLAUDE-LMS-MANUAL.md#34-skill-guard-hook), 흐름은 [diagrams/skill-guard-office-stop.mmd](../diagrams/skill-guard-office-stop.mmd).

- `claude-lms`가 붙이는 hook: PreToolUse matcher `Skill|Write|Edit|MultiEdit|Bash`, 그리고 matcher 없는 `Stop`. 둘 다 같은 `skill-guard`.
- **오피스 파일 거부**: 다음으로 `.docx .xlsx .pptx .hwpx`(옛 `.doc .xls .ppt .hwp`)를 만들면 거부하고, `from-md` 명령을 안내한다.
  - `Write`·`Edit`·`MultiEdit`
  - Bash 리다이렉트(`>` `>>` `>|` `&>` `N>`), `tee`의 모든 대상(`--` 포함)
  - 오피스가 아닌 파일을 오피스 이름으로 바꾸는 `mv`·`cp`
- **Bash 판정은 선형 lexer로 한다.** 처음 GLM 구현은 정규식이었다. codex 리뷰가 두 가지를 짚었다.
  - 놓치는 우회: 줄바꿈 뒤 명령, `>|`, `tee -- `, `mv a.md a.docx`
  - 잘못된 거부: 따옴표 안 `"> a.docx"`, 주석
  - 그래서 시험 26–29를 먼저 쓰고(RED) GLM이 글자 단위 lexer로 다시 썼다.
  - lexer는 따옴표·이스케이프·`#` 주석·연산자·heredoc 본문(`<<-` 탭 포함)·`<<<`를 안다.
  - 따옴표가 안 닫히는 등 확실하지 않으면 거부 규칙만 적용하고 표시는 지우지 않는다.
- **Stop 가드**:
  - 명령 파일이 있는 skill의 첫 `Skill` 호출을 허용할 때 `<세션>.pending`을 남긴다.
  - 그 skill의 `skills/N/scripts/N`이 명령 자리에서 help가 아닌 인자와 실행되면 지운다.
  - 표시가 남은 채 멈추려 하면 한 번 막는다.
  - `stop_hook_active`이거나 표시 삭제에 실패하면 막지 않는다.
- **알려진 한계(일부러 둠)**
  - `python -c "open('a.docx','w')"`, `install a.md a.docx`, 프로세스 치환 `tee >(…) a.docx`는 검사하지 않는다. 모델이 쓴 임의 프로그램을 막는 장치가 아니라 gemma의 흔한 실수를 고치는 안내 장치다.
  - 상대 경로 실행(`cd …/scripts && ./xlsx …`)은 실행으로 치지 않아 Stop이 한 번 더 요청한다.
  - 상태 폴더 생성 경합과 기록 파일 관련 LOW 지적은 §6.5와 같은 이유로 그대로 둔다.
  - codex 2차 리뷰 8건 중 `>& 파일`과 절대 경로 명령(`/bin/cp`)은 고쳤다(시험 30–31). 나머지는 그대로 둔다.
    - `"$(… > a.docx)"`처럼 큰따옴표 안 명령 치환 속 쓰기는 거부하지 않는다.
    - 실제로는 실행되지 않는 skill 실행도 표시를 지운다. 함수 정의 안, `false && …`, 따옴표 친 `'~/…'`가 그렇다. 이 경우 Stop이 막지 않을 뿐이라 안전한 쪽이다.
    - `cp -S .bak a.docx b.docx`는 잘못 거부된다.
    - 따옴표가 안 닫힌 명령도 거부 규칙은 적용한다. 일부러 이렇게 정했다.
- 구현 zai GLM `glm-5.3`(2회: 기본 구현, lexer 재작성), 시험 작성 Claude, 리뷰 codex(antigravity는 할당량 소진).
- 인수 시험: `accept_skill_guard.sh` 58 PASS / 0 FAIL. 200 KB 명령(평문·따옴표·heredoc 2만 줄·`;` 6만 개·괄호 5만 겹)은 모두 0.1초 안에 끝난다. `accept_xlsx` 84·`accept_docx` 77·`accept_pptx` 77·`accept_install_claude_code` 51·`accept_pack_claude_code` 108 PASS 그대로다.
- **2차 실전 시험**(운영 Mac, 같은 요청 7건, 2026-11-10):
  - 성공 기준: 요청한 파일 이름, 진짜 OOXML, 내용이 요청과 맞음.
  - 결과: xlsx 1/3, docx 1/3, pptx 0/1(1차 3/7 → 2/7).
    - docx 1건 더는 내용은 맞았지만 이름이 `주간보고.docx`였다.
    - pptx는 1건뿐이라 퇴보로 단정하지 않는다.
  - 가짜 오피스 파일은 2건에서 0건이 됐다. `Write 회의록.docx`는 거부됐고, 모델은 `.md`만 저장했다고 사실대로 답했다.
  - Stop 가드는 막아야 할 3건(xlsx2·xlsx3·pptx1)에서 모두 막았지만 한 건도 살리지 못했다. 새로 보인 실패는 다음과 같다.
    - gemma는 "Stop hook feedback:"을 사용자 지적으로 읽고 "앞으로는 … 하겠습니다"라고 글로만 답한 뒤 다시 멈춘다. 두 번째 멈춤은 `stop_hook_active`라서 허용된다.
    - heredoc 끝줄에 명령을 붙였다(`MD && …/xlsx from-md …`). bash는 이것을 본문으로 읽어 변환이 실행되지 않는다. zsh는 경고도 없이 "(no output)"을 낸다. 가드는 실행으로 치지 않아 표시를 남겼다(올바른 판정).
    - `Write` 거부 뒤 `.md`만 저장하고 멈췄다. `Skill`을 부르지 않아 표시가 없으니 Stop도 막지 않았다.
    - pptx1은 Bash 명령을 도구로 부르지 않고 ```` ```bash ```` 글로만 썼다.
    - docx의 `주간보고`, pptx의 `발표`는 SKILL.md 예시 파일 이름을 그대로 베낀 것이다.
  - 다음에 고칠 후보:
    - 끝나지 않은 heredoc 거부(끝줄 `MD`는 혼자, `from-md`는 다음 줄)
    - SKILL.md에 "사용자가 말한 파일 이름을 쓴다"는 규칙 추가
    - Stop 안내를 "파일이 아직 없다, 이번 답에서 Bash 도구를 부른다"로 바꾸고 두 번째 차단 허용 검토
    - 오피스 쓰기 거부 때도 표시 남기기

### 6.7 라운드 3: heredoc 거부, 파일 이름 규칙, Stop 두 번 (2026-11-11)

§6.6 끝에 적은 고칠 후보 네 가지를 모두 넣었다. 사용법은 [CLAUDE-LMS-MANUAL.md §3.4](../CLAUDE-LMS-MANUAL.md#34-skill-guard-hook), 흐름은 [diagrams/skill-guard-office-stop.mmd](../diagrams/skill-guard-office-stop.mmd).

- **끝나지 않은 heredoc 거부**: lexer가 끝 표시를 찾지 못한 heredoc이 있으면 거부하고 "끝 표시는 혼자 한 줄, 변환 명령은 그 다음 줄"을 알려 준다. 판정 순서는 오피스 쓰기 거부 → heredoc 거부 → (확실할 때만) 실행 확인과 표시 삭제다.
- **SKILL.md 규칙**: docx·xlsx·pptx의 `새로 쓰기:` 줄에 "파일 이름은 사용자가 말한 파일 이름을 그대로 쓴다(예시 이름은 예시일 뿐)"와 "끝 MD는 혼자 한 줄, 변환 명령은 다음 줄(`MD &&`처럼 붙이지 않는다)"을 넣었다.
- **Stop 문구와 두 번째 차단**: 표시는 `이름 / 차단 횟수 / 파일 이름` 세 줄이 됐다. 첫 차단은 "아직 파일이 없다, 원래 요청대로 이번 답에서 Bash 도구로 실행하라, 지어내지 말라"(Skill을 불렀으면 "다시 부르지 말라")이고, 두 번째는 더 짧은 다른 문구다. 세 번째부터, 또는 횟수가 깨졌으면 지우고 허용한다. `stop_hook_active`와 상관없이 같은 규칙이고, "앞으로"라는 말은 쓰지 않는다(gemma가 사용자 지적으로 읽고 다짐만 하던 일).
- **오피스 쓰기 거부 때도 표시**: 명령 파일이 있으면 거부하면서 표시를 남긴다. 파일 이름이 안전하면 그 이름을 넣어 Stop 안내가 `./회의록.md ./회의록.docx`처럼 구체적이다.
- **codex 리뷰 6건과 수정**(시험 36–40을 먼저 쓰고 GLM이 고침):
  1. HIGH 하위 셸·명령 치환 안의 `<<`를 모두 무시했다 → 산술 `(( ))`·`$(( ))` 안만 시프트로 보고 나머지는 heredoc으로 검사.
  2. HIGH 표시 읽고-고쳐-쓰기가 잠기지 않아 Stop과 동시 거부가 섞이면 횟수가 되돌아가 무한 차단이 될 수 있었다 → 세션별 `<sid>.lock`을 `flock`(비차단 40번 × 0.05초)으로 잠그고, 못 잠그면 막지 않는 쪽으로.
  3. MEDIUM 오피스 거부 뒤 첫 `Skill` 호출이 표시를 새로 써서 횟수와 파일 이름을 잃었다 → 횟수는 지키고 같은 skill이면 이름도 지킨다. 깨진 표시는 건드리지 않는다.
  4. MEDIUM 따옴표 없는 끝 표시 본문의 `\` 줄 잇기를 몰랐다 → 홀수 개 `\`로 끝나는 줄만 잇고, 따옴표 있는 끝 표시는 잇지 않는다(bash에서 확인).
  5. MEDIUM `<<$'EOF'`를 `$EOF`로 읽어 잘못 거부했다 → ANSI-C 따옴표를 풀고, 확신할 수 없는 이스케이프(`\x` `\0nn` `\u` `\c`)면 거부하지 않고 나머지를 본문으로 본다.
  6. MEDIUM 횟수 줄 해석이 느슨했다(빈 둘째 줄을 0으로, 아주 긴 숫자에 `int()`) → 1~3자리 숫자만, 옛 한 줄 형식만 0.
- 구현 zai GLM `glm-5.3`(2회: 라운드 3 구현, 리뷰 수정), 시험 작성 Claude, 리뷰 codex(2회).
- 인수 시험: `accept_skill_guard.sh` 75 PASS / 0 FAIL, `accept_docx` 77·`accept_xlsx` 84·`accept_pptx` 77·`accept_install_claude_code` 51·`accept_pack_claude_code` 108 PASS.
- **알려진 한계(일부러 둠)**
  - 잠금 파일 `<sid>.lock`은 지우지 않는다(지우면 기다리던 쪽의 잠금이 깨진다). 임시 폴더라 재부팅 때 정리된다.
  - `((cmd); …)`처럼 괄호를 붙여 쓴 하위 셸은 산술로 본다. bash도 같게 읽는다.
  - Skill 호출 기록 파일(되풀이 판정용)은 잠그지 않는다. 동시 호출이 둘 다 "첫 호출"로 허용될 수 있을 뿐이다.
  - codex 2차 리뷰(수정본) 5건은 고치지 않았다. 모두 gemma가 쓰지 않을 bash 모양이고, 표시를 지우는 쪽은 Stop이 막지 않을 뿐이라 안전한 쪽이다.
    - 산술 안 명령 치환 속 heredoc(`(( x = $(cat <<EOF … ) ))`)의 본문을 명령으로 읽는다. 잘못 거부하거나 표시를 지울 수 있다.
    - bash가 문법 오류로 거부하는 `echo ((; …/xlsx from-md …`를 실행으로 쳐서 표시를 지운다.
    - `echo > $'safe\0.docx'`처럼 풀이가 불확실한 ANSI-C 이름도 오피스 이름이면 거부한다.
    - 횟수 줄 ` 0 `(앞뒤 공백)을 0으로 읽는다. 이름 줄이 깨진 표시는 첫 `Skill` 호출이 새로 쓴다(최대 두 번 차단은 그대로).
- **3차 실전 시험**(운영 Mac, gemma-4-e4b, 키트 `officekit9-20261110T1555Z`, 결과 `~/bundles/office-live-20261110T155654Z/`, 한 건 69–168초)

  | 사례 | 결과 | 흐름 |
  |---|---|---|
  | xlsx1 | 성공 | Skill → Bash 2번. `예산.xlsx`, B5 `=SUM(B2:B4)` |
  | xlsx2 | 실패 | Skill만 부름 → 안내를 "프로토콜"로 읽고 "이해했습니다"라고 글로 답함 → Stop 2번 차단에도 글 답("다음에 작업 지시가 주어지면…") → 횟수 2에서 표시 지움 |
  | xlsx3 | 실패 | xlsx2와 같은 모양("파일이 준비되면…") |
  | docx1 | 성공 | `Write ./회의록.docx` 거부(표시 남김) → Stop 1번 → Bash. 내용 맞음(제목은 "회의록", 작성일을 지어냄) |
  | docx2 | 이름 틀림 | Skill → Bash 1번. `회의록.md`는 맞게 썼는데 변환 출력이 `회의록_11월.docx`. 내용 맞음 |
  | docx3 | 실패(새 모양) | 도구를 하나도 안 부르고 "'회의록.docx' 파일을 생성했습니다"라고 답함. 표시가 없어 Stop이 못 잡음 |
  | pptx1 | 이름 틀림 | 없는 Skill `itakan/docs-pptx` → `pptx` → Bash. `계획.md`는 맞는데 출력이 SKILL 예시 이름 `발표.pptx`. 내용 맞음 |

  - 엄격 2/7(이름까지 맞아야 성공), 이름 틀림을 쳐 주면 4/7. 1차 3/7, 2차 2/7.
  - 효과가 보인 것: 오피스 쓰기 거부 표시(docx1, 2차 실패 모양 (c)가 고쳐짐), heredoc 실수(`MD &&`)는 한 번도 안 나옴.
  - 효과가 없던 것: Skill만 부른 뒤의 Stop 차단은 두 번 다 글 답으로 끝났다. Stop 차단 뒤 Bash로 이어진 것은 오피스 거부 경로뿐이다.
  - 파일 이름 규칙은 반쯤만 먹혔다. `.md` 이름은 사용자 이름을 따르지만 변환 출력 이름에서 예시 이름이나 덧붙인 이름이 나온다.
  - 세는 법 주의: 대화 기록에서 Stop 차단 하나가 user·attachment·system 세 줄로 남는다. 분석 스크립트의 "stop blocks: 6"은 실제 2번이다.

### 6.8 라운드 4: 한 인자 from-md, 끝 답 주장 검사, 명령형 첫 줄 (2026-11-11)

§6.7의 3차 실전 시험에서 남은 실패 모양 세 가지(이름 틀림, "이해했습니다" 글 답, 도구 없이 "생성했습니다")를 겨냥했다. 사용법은 [CLAUDE-LMS-MANUAL.md §3.4](../CLAUDE-LMS-MANUAL.md#34-skill-guard-hook).

- **한 인자 `from-md`**: 네 도구(`docx xlsx pptx hwpx`)의 `from-md <in.md> [out]`에서 출력을 생략하면 입력의 확장자만 바꾼 경로가 된다(`./회의록.md` → `./회의록.docx`). 이미 있는 출력·입력과 같은 출력은 전처럼 거부하고, 인자가 0개나 3개 이상이면 rc 2다. SKILL 예시와 skill-guard 안내 명령은 모두 한 인자 꼴이 됐다. 이름을 두 번 쓸 일이 없으니 docx2(`회의록_11월.docx`)·pptx1(예시 이름 `발표.pptx`)처럼 출력 이름만 틀리는 길이 사라진다.
  - hwpx는 macOS에서 `/tmp`가 `/private/tmp`로 풀려 "입력과 같은 출력" 비교가 어긋나지 않게, `PWD`의 실제 경로가 `getcwd()`와 같을 때만 `PWD`를 믿는 `logical_cwd()`를 넣었다.
- **명령형 첫 줄**: 네 SKILL.md의 frontmatter 다음 첫 줄을 "이 안내를 읽었으면 지금 바로 Bash 도구로 아래 명령을 실행해 파일을 만든다. '이해했습니다' 같은 글 답으로 끝내지 않고, Skill 을 다시 부르지 않는다."로 바꿨다(xlsx2·xlsx3의 "프로토콜을 이해했습니다" 답 대응).
- **Stop: 끝 답 주장 검사**(docx3 대응): 표시(`.pending`)가 막지 않을 때만 `last_assistant_message`를 문장으로 나눠 "생성·만들·저장·작성·완료·created·saved"와 함께 나온 새 형식 오피스 이름을 찾는다. 그 파일이 `cwd` 기준으로 일반 파일이 아니거나 zip 머리가 아니면 세션마다 한 번(`<sid>.claim`) 막고 그 이름의 한 인자 명령과 "만들 수 없으면 사실대로 말하라"를 준다.
  - 이름: 백틱 안 전체(띄어쓰기·괄호 포함), `**`·따옴표, Markdown 링크는 대상 경로만(`%20` 등을 풀고, 웹 주소는 버림), `~/`는 HOME 기준, `+` 포함. 확장자 뒤 경계는 ASCII로 봐서 조사가 붙은 `회의록.docx를`은 이름이고 `report.docx.md`·`report.docx2`는 아니다.
  - 주장이 아님: `?`·`？`로 끝난 물음, 파일 이름을 지운 나머지에 주장 말이 없거나 부정(못·않·실패·없·failed·could not·couldn't·unable·not·n't·never)이나 만드는 방법 안내(려면·세요·십시오·to create·if)가 있는 문장, 옛 형식(`.doc .xls .ppt .hwp`), 웹 주소.
  - 파일 확인은 `O_NONBLOCK`으로 열고 `fstat`로 일반 파일인지 본 뒤 앞 4바이트만 읽는다. `.claim`이 있으면 파일을 열기 전에 허용한다.
- **Stop 안내의 이름을 대화 기록에서**: Skill만 부르고 멈춰 표시에 이름이 없으면 `transcript_path` 끝 4MB(논블로킹, 일반 파일만, 1MB 넘는 줄은 건너뜀)에서 마지막 `last-prompt`를 찾아 그 skill과 같은 확장자의 첫 안전한 이름을 쓴다. 옛 요청·다른 종류 이름은 쓰지 않는다.
- **검토와 수정**
  - codex 리뷰(1차 구현): HIGH FIFO 주장 파일에서 `open()`이 멈춤, `.claim`을 파일 확인 뒤에 봄, 띄어쓰기 이름·Markdown 링크·`report.docx.md` 오인, 물음과 영어 부정 미처리, 옛 형식까지 주장으로 봄 → 시험 45를 먼저 쓰고 GLM이 고침.
  - Claude 검토(2차 수정본): `\w`가 한글을 포함해 `회의록.docx를 생성했습니다`와 요청의 `주간회의록.docx로 만들어줘`를 둘 다 놓침(시험 문장이 모두 "회의록.docx 를"처럼 띄어 써서 통과했음) → 시험 46을 먼저 쓰고 GLM이 경계를 ASCII로 고침.
  - codex 재검토(3차 수정본): HIGH 이름 정규식이 낱말 중간마다 다시 시작해 20만 자 끝 답·30만 자 요청에서 제곱 시간(5초 넘김), 닫히지 않은 `[` 반복도 같음. MEDIUM `report+final.docx`→`final.docx`, 링크 `my%20report.docx`→`20report.docx`, 웹 주소를 로컬 `//example.com/…`로 봄, 이름 안의 글자(`created.docx`·`saved.xlsx`)가 주장 말이 됨, "생성하려면 … 실행하세요" 안내를 주장으로 봄 → 시험 47을 먼저 쓰고 GLM이 고침.
    - 이름은 낱말 첫머리에서만 시작(앞 부정 lookbehind, `:` 포함)하고 길이 255 상한, 링크 라벨에서 `[`를 빼고 길이 상한, 끝 답·요청은 끝 20000자만 본다 → 최악 입력 약 0.04초.
    - 이름 글자에 `+`(백틱 안은 괄호도), 링크 대상은 `unquote`, 스킴·`//`로 시작하면 버림. 주장 말·부정 말·조건·권유 말(`려면 세요 십시오 to create|save|make|generate if`)은 모두 이름을 지운 나머지에서 본다.
  - codex 3차 검토(4차 수정본): HIGH 없음. 남은 MEDIUM은 알려진 한계로 둔다.
    - 주장 말·부정 말을 찾는 나머지 글에 Markdown 링크 원문이 남는다. 그래서 `[다운로드](../created report.docx)`는 주장으로 막히고, `Created [report](../not here.docx).`는 놓친다.
    - 같은 문장의 권유는 완료 주장도 허용 쪽으로 돌린다(`…생성했습니다, 다운로드하세요.`). 놓치는 쪽은 허용이고, 앞 단계의 표시 차단이 남아 있으므로 그대로 둔다.
- 구현 zai GLM `glm-5.3`(4회: 구현, codex 지적 수정, 조사 수정, codex 재검토 수정), 시험 작성 Claude, 리뷰 codex 3회 + Claude.
- 인수 시험(모두 ACCEPT PASS, FAIL 0): skill_guard 94, docx 80, xlsx 87, pptx 80, hwpx 407, install_claude_code 51, pack_claude_code 108.
- **4차 실전 시험**(운영 Mac, gemma-4-e4b, 2026-11-12)
  - 설치: 키트 `claude-code-kit-2.1.321-20261111T0122Z-macos-arm64`를 `~/bundles/claude-code-kitinstall-20261111T0122Z/`에 받아 두 SHA256 검사 후 설치(rc 0). 설치본의 skill_guard·SKILL.md 4개·도구 스크립트·claude-lms·skill-guard 해시가 저장소와 같다. 옛 skill은 `~/.claude/skills-backup/*.20261112-000241.2165`.
  - 결과 폴더 `~/bundles/office-live-20261111T150315Z/`, 3차와 같은 요청 7건, 한 건 188–545초.

  | 사례 | 결과 | 흐름 |
  |---|---|---|
  | xlsx1 | 실패 | Skill → 빈 답 → 글 답("명확히 이해했습니다") → Stop 2번 차단에도 글 답("다음 작업 시에는…") |
  | xlsx2 | 성공 | 빈 답 뒤 Bash 1번(heredoc + `xlsx from-md ./예산.md`). `예산.xlsx`, `=SUM(B2:B4)` |
  | xlsx3 | 성공 | Skill → Bash. Stop 없음 |
  | docx1 | 성공 | `Write ./회의록.docx` 거부 → `회의록.md`를 Write로 쓰고 멈춤 → Stop 1번 글 답 → Stop 2번(정확한 한 인자 명령)에 Skill → Bash. `회의록.docx` 6문단 |
  | docx2 | 이름 틀림 | Skill → Bash. `.md` 단계부터 `주간회의록.md` → `주간회의록.docx`(제목 "11월 주간 회의"에서 지은 이름). 파일이 있으니 끝 답 검사도 통과 |
  | docx3 | 성공 | 빈 답 2번 뒤 Bash. `회의록.docx` 7문단 |
  | pptx1 | 이름 틀림 | 없는 Skill `itakan` → `pptx` → Bash. `.md`부터 SKILL 예시 이름 `발표.md` → `발표.pptx`(3장) |

  - 엄격 4/7(3차 2/7), 이름 상관없이 파일 생성 6/7(3차 4/7).
  - 효과가 보인 것: Stop 안내의 정확한 한 인자 명령(docx1이 두 번째 차단 뒤 Bash로 이어짐). 도구 없이 "생성했습니다"(3차 docx3 모양)는 나오지 않았다. 명령형 첫 줄 뒤 Skill → Bash 직행이 늘었다(xlsx3, docx2).
  - 남은 실패 모양 둘
    - 이름 틀림: 한 인자 `from-md`로 출력 이름만 틀리는 길은 사라졌지만, 이제 `.md` 이름부터 예시 이름(`발표`)이나 제목에서 지은 이름(`주간회의록`)을 쓴다. 파일이 실제로 있으니 skill-guard가 못 잡는다.
    - Stop 차단에 글 답: xlsx1은 두 번 다 "다음에는…"으로 답했다.
  - 해석 주의: xlsx SKILL 예시 이름이 `./예산.md`라 요청 이름과 같다. xlsx 이름 성공에는 예시를 베낀 몫이 섞여 있을 수 있다(docx·hwpx 예시는 `주간보고`, pptx는 `발표`).
  - 새로 보인 것: Skill을 읽은 뒤 gemma가 빈 답을 내면 Claude Code가 "[Your previous response had no visible output…]"로 이어 가게 한다(xlsx1·xlsx2·docx3). 3차에는 없었다. 이것 자체가 실패 원인은 아니었다(xlsx2·docx3 성공).

### 6.9 라운드 5: 중립 예시 이름, from-md 결과 이름 검사 (2026-11-12)

§6.8의 4차 실전 시험에서 남은 "이름 틀림"(docx2 `주간회의록`, pptx1 `발표`)을 겨냥했다. 파일이 실제로 생겨 Stop·끝 답 검사로는 못 잡으므로, 변환 **전**의 Bash 명령에서 막는다. 사용법은 [CLAUDE-LMS-MANUAL.md §3.4](../CLAUDE-LMS-MANUAL.md#34-skill-guard-hook).

- **중립 예시 이름**: 네 SKILL.md의 예시 이름을 사용자가 흔히 요청하는 이름(`회의록 예산 계획 발표 주간…`)과 겹치지 않게 바꿨다. docx `출장보고`, xlsx `재고현황`, pptx `신제품소개`, hwpx `행사안내`. 각 이름은 `cat >` 줄, `from-md` 줄, `(./X.md → ./X.T)` 줄에서 같다(시험 49). 예시를 베끼면 이제 요청과 확실히 달라 아래 검사에 걸리고, §6.8 "해석 주의"의 xlsx 예시(`예산`)와 요청 이름이 같아 성공에 베낀 몫이 섞이던 문제도 없어진다.
- **PreToolUse·Bash 이름 검사**: `handle_bash` 순서는 오피스 리다이렉트 거부 → 오피스 형식 거부 → 끝나지 않은 heredoc 거부 → **이름 검사**(lexer가 확실할 때만) → 실행 표시 지우기.
  - 대상: `skills/T/scripts/T from-md` simple command. 결과 이름은 피연산자가 둘이면 둘째에서 `.T`(없으면 마지막 확장자)를 뺀 것, 하나면 md 이름에서 `.md`를 뺀 것. 결과 이름(두 인자면 입력 md 이름도)에 셸 확장 글자(`$` `` ` `` `*` `?` `[` `{` `\`)가 있으면 이름을 알 수 없어 건너뛴다(lexer의 `sure`는 따옴표 안 `"$N.md"`도 확실하다고 보므로 따로 거른다).
  - 요청 이름: transcript 끝 4MB의 마지막 `last-prompt`(새 `_last_prompt()`를 Stop 쪽 `transcript_stem`과 함께 씀)를 NFC로 정리해 끝 20000자에서 그 종류 이름을 모두 찾는다(`CLAIM_NAME_RE`, `safe_stem` 통과분). 맞음 = 그 stem 가운데 하나와 같거나, 요청 글에 `(?<![\w.\-+])<stem>\.T(?![A-Za-z0-9])`가 나옴(띄어쓰기 든 이름).
  - 허용: 요청 이름이 모두 이미 있음(덮어쓰기 거부라 막다른 길), 세션·종류마다 거부 2번 넘음(`<sid>.name-T`), 기록·`cwd`·잠금·`command_path` 중 하나라도 불확실, 예외.
  - 거부 문구: 후보를 모두 `./이름.T`로 적고, 같은 명령이 md를 리다이렉트로 썼으면 `cat > ./<첫 후보>.md <<'MD'`와 `<명령> from-md ./<첫 후보>.md` 두 줄, 아니면 두 인자 명령 `<명령> from-md <입력> ./<첫 후보>.T`(입력이 `[\w./-]+`가 아니면 `shlex.quote`로 감싼다). 후보가 여럿이면 두 줄 안내에는 "두 곳의 <첫 후보> 자리에(확장자 없이)", 두 인자 안내에는 "`./<첫 후보>.T` 자리에" 다른 이름을 쓰라고 더한다.
  - `.pending` 표시는 건드리지 않는다. 거부된 명령은 돌지 않았으므로 Stop 가드가 그대로 이어진다(시험 48h).
- **시험(Claude 작성, 구현 전 RED 확인)**: 48 두 인자 안내·표시 유지·바른 명령 허용, 48b 같은 명령 재전송 두 줄, 48c 같은 이름·NFD 요청·따옴표 출력 허용, 48d 입력·출력 이름이 다른 요청(`메모.md`→`보고서.docx`), 48e 후보 여럿·있는 출력, 48f 종류별 거부 2번 상한, 48g fail-open 9가지(FIFO는 5초 제한), 48h heredoc 거부 뒤 표시 유지, 49 예시 이름 중립. 리뷰 뒤 추가: 48i 빈칸 든 입력의 안내 따옴표(안내를 `shlex.split`하면 네 낱말, 그대로 보내면 허용), 48j 입력 자리 확장 글자 4가지 허용, 48k 같은 명령·후보 여럿 문구.
- 구현 zai GLM `glm-5.3`(첫 구현 25턴, 리뷰 반영 21턴). 리뷰: codex는 사용 한도로 실패(2026-11-14 재개 뒤 다시 돌릴 것), agy(`gemini-3.8-flash-high`)로 대신했다. agy 지적과 처리:
  - HIGH 두 인자 안내가 빈칸 든 입력(`"./my draft.md"`)을 따옴표 없이 옮겨, 안내대로 보내면 다시 거부되는 교착 → 입력이 `NAME_INPUT_RE`에 안 맞으면 `shlex.quote`(전에는 폴더를 버리고 basename만 썼다). 시험 48i.
  - HIGH 두 인자에서 입력 피연산자의 확장 글자를 안 걸러 `from-md "$INPUT" ./wrong.docx`에 `./$INPUT` 안내 → 그 명령은 건너뜀(fail open). 시험 48j.
  - MEDIUM 같은 명령에서 md를 쓴 경우 후보가 여럿이면 두 줄 틀에 없는 `./계획.pptx 자리`를 말해 `./요약.pptx.md`를 부를 수 있음 → "두 곳의 계획 자리에 그 이름(확장자 없이)". 시험 48k.
  - LOW `skills/pptx/scripts/pptx from-md …`처럼 `/` 없이 시작하는 상대 경로는 검사하지 않음 → 기존 명령 경로 규칙(끝이 `/skills/T/scripts/T`)과 같아 알려진 한계로 둔다. SKILL.md는 모두 `~/.claude/...` 전체 경로를 쓴다.
- 인수 시험(모두 ACCEPT PASS, FAIL 0): skill_guard 106, docx 80, xlsx 87, pptx 80, hwpx 407, install_claude_code 181, pack_claude_code 125.
  - hwpx는 Python 3.13 venv 기준. 3.15에서는 `json-too-deep-a/o` 2건이 실패한다. 3.15의 `json`이 10만 겹 중첩도 RecursionError 없이 읽어 "너무 깊음" 경로를 타지 않기 때문이고, 이번 변경과는 무관하다(후속 과제: `hwpx_tool.py`에 명시적 깊이 상한).
  - **해결됨(2026-11-12)**: `parse_values_text`가 JSON을 읽은 뒤 반복문으로 겹수를 세어(`json_depth_exceeds`, dict·list만 셈) `MAX_JSON_DEPTH = 1000`을 넘으면 같은 "너무 깊음" 오류를 낸다. 상한은 3.13 `json` C 스캐너의 재귀 한계(약 1만 겹, 실측 9997)보다 낮게 잡아, 어느 깊이에서든 두 버전의 오류 문구가 같다. `bare_pairs_retry`의 다시 읽기도 같은 함수를 거친다. 구현 zai GLM `glm-5.3`. 리뷰 agy(`gemini-3.8-flash-high`): CRITICAL·HIGH·MEDIUM 없음, LOW 1건(잎 값도 스택에 넣는 할당, 50만 키에서 약 40ms)은 효과가 작아 두었다. codex는 사용 한도로 다시 실패(2026-11-14 재개). hwpx 인수 시험은 Python 3.13·3.15 모두 407 PASS / ACCEPT PASS.
- **5차 실전 시험**(운영 Mac, gemma-4-e4b, 2026-11-12)
  - 설치: 키트 `claude-code-kit-2.1.322-20261112T1156Z-macos-arm64`(커밋 3a8be67, 위 깊이 상한 수정 전)를 `~/bundles/claude-code-kitinstall-20261112T1156Z/`에 받아 두 SHA256 검사 후 설치(rc 0). Claude Code 2.1.321 → 2.1.322(2.1.321은 `versions/`에 남김). 설치본 15개 파일(SKILL.md 4개, skill_guard·skill-guard, 도구 스크립트, claude-lms)의 해시가 저장소와 같다. 옛 skill은 `~/.claude/skills-backup/*.20261112-220524.65077`.
  - 결과 폴더 `~/bundles/office-live-20261112T130555Z/`, 4차와 같은 요청 7건(`run.sh` 그대로), 한 건 232–668초.

  | 사례 | 결과 | 흐름 |
  |---|---|---|
  | xlsx1 | 성공 | Skill → "(Waiting…)" 글 답 → Stop 1번에 "이해했습니다. 향후부터는…" 글 답 → Stop 2번(한 인자 명령)에 Bash 2번(heredoc, `from-md`). `=SUM(B2:B4)` |
  | xlsx2 | 성공 | `Write 예산.xlsx` 거부 → 탭 글자로 `예산.md` Write → Skill → `from-md` "표가 없습니다" → md를 표로 다시 Write → `from-md`. Stop 없음 |
  | xlsx3 | 성공 | Skill → Bash 2번. 개입 없음 |
  | docx1 | 성공 | Skill만 부르고 멈춤 → Stop 1번에 Bash. `회의록.docx` |
  | docx2 | 성공 | `Write ./회의록.docx` 거부 → `회의록.md` Write → Stop 1번에 Bash |
  | docx3 | 성공 | Skill → Bash. 개입 없음 |
  | pptx1 | 성공 | Skill → `MD && …` 한 줄(heredoc 거부) → md만 따로 저장(`계획_하반기.md`) → `from-md ./계획_하반기.md` **이름 검사 거부** → `-o` 붙여 rc 2 → 안내의 두 인자 명령으로 `계획.pptx`(3장) → 끝 답 검사 오탐(아래) → 다시 만들려다 "이미 존재" → 끝 |

  - 엄격 7/7(4차 4/7, 3차 2/7). 모든 파일 이름이 요청과 같고 `file`이 OOXML로 본다.
  - 효과가 보인 것: 새 이름 검사가 실전에서 처음 걸렸고(pptx1, 제목에서 지은 `계획_하반기`), 두 인자 안내를 그대로 따라 요청 이름이 됐다. 중립 예시 이름 뒤로 예시를 베낀 이름(`발표`)은 나오지 않았다. 4차에 실패한 xlsx1 모양(Stop 2번 모두 글 답)은 이번에 두 번째 차단에서 Bash로 이어졌다.
  - 남은 문제(새로 찾음): **끝 답 주장 검사의 절대 경로 오탐**. pptx1 끝 답 "`/계획.pptx` 파일로 성공적으로 생성"에서 백틱 안 `/계획.pptx`를 루트의 절대 경로로 보고 없다며 막았다. 실제 파일은 `cwd/계획.pptx`에 있었다. 모델이 다시 만들려다 덮어쓰기 거부로 멈춰 결과는 해가 없었지만 한 턴을 더 썼다. → **고침(2026-11-13)**: 주장한 이름이 `/` 바로 아래 이름 하나(`os.path.dirname(이름) == "/"`, 예 `/계획.pptx`)이면 그 절대 경로나 `cwd/계획.pptx` 중 하나만 zip이어도 있는 것으로 본다(`_claim_present`). 더 깊은 절대 경로(`/Users/nobody/x.docx`)는 `cwd`에 같은 이름이 있어도 그 절대 경로만 본다. 인수 시험 50(50a 허용 3형태, 50b `cwd`에 없거나 zip이 아니면 막음, 50c 깊은 경로는 막음)을 먼저 써서 50a 실패를 확인한 뒤 GLM이 구현했다.
  - 해석 주의: 7건 한 번씩이라 표본이 작다. docx·pptx는 요청 이름(`회의록`·`계획`)이 예시 이름과 다르니 이름 검사 효과의 증거가 되고, xlsx는 이번에도 요청 이름 `예산`을 바로 썼다(예시 `재고현황`과 다름).

## 7. 구현과 검토 분담

- 구현(스크립트, kit 구성, `install-claude-code.sh` 변경)은 zai API 에이전트에 맡긴다.
- 검토는 codex와 antigravity(agy) review로 교차 확인한다.
- 커밋과 푸시는 사내 Git 서버에서, 사용자가 요청할 때만 한다.

## 8. 라이선스

- Anthropic docx·xlsx·pptx skill(anthropics/skills commit `2c5958e`)의 라이선스는 **Apache-2.0**이다(2026-11-10 확인). pdf skill 폴더는 확인하지 않았고 쓰지도 않는다. 우리 도구는 그 지침에서 작성 규칙만 가져왔고 코드는 복사하지 않았다. 고지는 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)에 있다.
- moai-officer 플러그인(Apache-2.0)의 doc-* skill은 kordoc MCP와 Node에 의존한다. 그래서 그대로 쓰지 않고, 구성 아이디어만 참고한다.
- python-hwpx는 Apache-2.0이다. wheel은 수정 없이 동봉한다. 별도 `NOTICE` 파일은 두지 않았다. 제3자 고지는 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)에 적었고, 라이선스 전문과 원저작자 NOTICE는 휠 안(`dist-info/licenses/`)에 들어 있다.

## 9. 별도 후속 작업

- ~~"Open WebUI에는 Skills가 없다"는 서술 고치기~~ → **반영 완료(2026-11-10)**.
  - [DOCUMENT-TOOL.md](../DOCUMENT-TOOL.md) §3("skill"로 만들기)은 "Open WebUI 0.12.3에는 네이티브 Skills 기능이 있다. 이 문서는 Tool 등록을 다룬다"로 고쳤다.
  - `build_registration_guide.py` STEP 3의 "권장(skill화)" 표현은 "권장(전용 모델)"로 고쳐 `문서생성기-등록-가이드.pptx`를 다시 생성했다.
