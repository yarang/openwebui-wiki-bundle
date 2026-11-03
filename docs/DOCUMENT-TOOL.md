# 문서 생성기 — Open WebUI에 docx/pptx/xlsx 작성 Tool 등록

Open WebUI 채팅에서 모델이 **Word 보고서·회의록, PowerPoint 발표자료, Excel 표**를
만들어 **다운로드 링크**로 돌려주게 하는 네이티브 Tool입니다.
(Claude의 docx/pptx Skill과 같은 개념 — 모델이 필요할 때 호출합니다.)

## 0. 동작 원리 (근거)

생성한 바이너리를 Open WebUI의 `upload_file_handler(process=False)`로 Files 스토리지에
저장하고 `/api/v1/files/{id}/content` 링크를 반환합니다. docx/pptx/xlsx는 PDF·텍스트가
아니므로 이 엔드포인트가 `Content-Disposition: attachment`를 붙여 **브라우저 다운로드를
강제**합니다(`routers/files.py`). 접근제어(소유자/admin)도 프레임워크가 처리합니다.

양식은 **실제 Office 파일 기반**입니다 — `document-templates/theme-default.docx`의 스타일
(폰트·색·제목 스타일)을 열어 채웁니다. 테마 파일이 없으면 동일 스타일을 코드로 폴백 생성합니다.

## 1. 사전 준비 (설치)

`install.sh`가 문서 라이브러리(python-docx·python-pptx·openpyxl)를 오프라인으로 설치합니다.
이미 설치한 장비라면 한 번만:

```bash
cd <번들 경로>
uv pip install --python .venv/bin/python --offline --no-index \
  --find-links=openwebui-packages python-docx python-pptx openpyxl
```

테마 참조 파일은 저장소에 포함되어 있습니다. 새로 만들거나 갱신하려면:

```bash
.venv/bin/python document-templates/build_theme.py   # theme-default.docx/pptx 생성
```

## 2. Tool 등록 (핵심)

1. Open WebUI → **Workspace → Tools → ➕ (Create Tool)**
2. `open-webui-tools/document_generator.py` 내용을 **그대로 붙여넣기** → **Save**
3. 방금 만든 Tool의 **⚙️ Valves**에서 `templates_dir`을 **번들 안 `document-templates` 절대경로**로 설정
   예: `/Users/<계정>/openwebui/document-templates`
   (비워두면 코드 내장 기본 테마로 동작 — 파일 편집형 양식은 못 씀)

> Tool 코드는 Open WebUI DB에 저장됩니다. 이후 코드를 고치면 **다시 붙여넣어** 갱신하세요.

## 3. "skill"로 만들기 — 모델 프리셋 (권장)

Open WebUI엔 Claude식 Skill이 없어, **커스텀 모델**로 "문서 작성 도우미"를 만들면
드롭다운에서 골라 쓰는 skill처럼 동작합니다.

1. **Workspace → Models → ➕**
2. Base Model 선택 → 이름 "문서 작성 도우미"
3. **Tools**에서 위 문서 생성기 Tool 활성화
4. **System Prompt** 예시:

```
너는 문서 작성 도우미다. 사용자가 보고서/회의록/발표자료/표를 요청하면,
먼저 필요한 내용을 정리한 뒤 알맞은 도구를 호출해 파일을 생성하고 다운로드 링크를 제시한다.
- 보고서 → create_report (본문은 '# 대제목', '## 소제목', '- 불릿' Markdown)
- 회의록 → create_minutes (일시·장소·참석자·안건·결정·액션아이템)
- 발표자료 → create_slides (슬라이드는 '---' 로 구분, 각 슬라이드 '# 제목' + '- 불릿')
- 표/데이터 → create_spreadsheet (Markdown 표 또는 CSV, 첫 행은 머리글)
어떤 양식이 있는지 모르면 list_document_templates 를 먼저 호출한다.
```

## 4. 사용 예 (채팅)

| 요청 | 결과 |
| --- | --- |
| "이번 분기 성과를 보고서로 만들어줘" | `create_report` → report.docx 다운로드 링크 |
| "오늘 회의 내용을 회의록으로 정리해줘" | `create_minutes` → minutes.docx |
| "이 내용을 5장짜리 발표자료로" | `create_slides` → slides.pptx |
| "이 수치를 엑셀 표로 만들어줘" | `create_spreadsheet` → data.xlsx |

## 4-1. 표 · 머리글/바닥글 세밀 제어

**머리말/끝말 문구** — `create_report`/`create_minutes` 의 `header`·`footer` 파라미터:
- `header` → 머리글 오른쪽 (기관명 왼쪽은 Valve `org_name`). 예: `대외비`, 문서번호
- `footer` → 바닥글 왼쪽 (페이지 번호는 가운데 자동). 예: `© 2026 운영팀`
- 채팅 예: "머리글에 '대외비', 바닥글에 저작권 넣어서 보고서로"

**표 정렬** — 마크다운 구분선 마커:
```
| 지표 | 값 | 증감 |
|:---|---:|:---:|      ← 좌 / 우 / 가운데 정렬
```

**표 캡션·열 너비** — 표 바로 앞 지시문:
```
표: 분기별 핵심 지표     ← 표 위 캡션
너비: 1,2,2,2            ← 상대 열 너비(비율)
| 지표 | 1Q | 2Q | 증감 |
|---|---|---|---|
```

**표 스타일** — Tool Valve `table_style`: `grid`(기본) / `plain` / `striped` / `minimal`
(또는 docx 내장 스타일명 직접). 문서 전체 표에 적용됩니다.

## 5. 양식(테마) 수정 · 추가

### 구조형 테마 (표지·머리글/바닥글)
테마 `theme-<이름>.docx` 는 스타일뿐 아니라 **문서 틀**을 담습니다:
- **표지 페이지** — `{{TITLE}}` `{{SUBTITLE}}` `{{META}}` `{{LOGO}}` 자리표시자를 생성 시 실제 값으로 치환
- **머리글** — `{{ORG}}`(기관/팀 이름) + 하단 경계선
- **바닥글** — 가운데 페이지 번호
- 본문은 표지 다음 페이지부터 시작

기관명·로고는 Tool **⚙️ Valves** 로 지정합니다:
- `org_name` — 머리글·표지에 넣을 기관/팀 이름 (`{{ORG}}`)
- `logo_path` — 표지 로고 이미지 절대경로(PNG/JPG). 비우면 로고 없음

> 자리표시자가 없는 옛 스타일-only 테마는 그대로 동작합니다(표지 없이 제목부터).

### 기존 테마 수정
`document-templates/theme-default.docx`를 **Word로 열어** 폰트·색·제목 스타일
(`T Cover`, `T Title`, `T H1`, `T H2`, `T Body` 등)이나 표지·머리글 문구를 바꾸고
저장하면 바로 반영됩니다. (`{{...}}` 자리표시자는 그대로 두세요)

### 테마 추가 (여러 개 두고 선택)
`document-templates/`에 **`theme-<이름>.docx`**(선택적으로 `theme-<이름>.pptx`)를 넣으면
자동으로 선택지가 됩니다. 만드는 두 가지 방법:

1. **스크립트로 생성** — 이름과 강조색(hex)을 지정:
   ```bash
   .venv/bin/python document-templates/build_theme.py corporate 1F4E79   # theme-corporate.*
   .venv/bin/python document-templates/build_theme.py mint 0F766E
   ```
2. **Word로 편집** — `theme-default.docx`를 `다른 이름으로 저장 → theme-<이름>.docx`,
   스타일(`T Title`, `T H1` …)의 **서식만** 바꿉니다. **스타일 이름은 유지**해야 합니다
   (이름이 빠져도 코드가 자동 보강하지만, 서식은 default가 됩니다).

사용:
```
"이 내용을 corporate 테마로 보고서 만들어줘"
→ create_report(..., template="corporate")
```
현재 어떤 테마가 있는지는 채팅에서 `list_document_templates` 로 확인합니다.

**pptx 강조색도 테마를 따릅니다** — 발표자료의 제목 바·강조선 색은 해당 테마
`theme-<이름>.docx` 의 `T Title` 색에서 자동으로 가져옵니다(docx·pptx 단일 소스).
즉 테마 하나만 만들면 보고서와 발표자료가 같은 색으로 나옵니다. (폰트는 `KR_FONT` 상수)

## 6. 문제 해결

| 증상 | 조치 |
| --- | --- |
| Tool 목록에 안 보임 | Workspace→Tools 저장 확인. 모델의 Tools에서 활성화했는지 확인 |
| `No module named 'docx'` | 1장 사전 준비의 라이브러리 설치 |
| 다운로드가 텍스트로 열림 | 정상은 attachment 강제 다운로드. 브라우저/프록시 확인 |
| 한글 폰트가 다르게 보임 | 대상 PC에 `Apple SD Gothic Neo`(macOS) 존재. 다른 폰트면 테마 파일/상수 변경 |
| 양식 편집이 반영 안 됨 | Valve `templates_dir`이 실제 `document-templates` 절대경로인지 확인 |

## 7. 검증 현황

| 항목 | 상태 |
| --- | --- |
| docx/pptx/xlsx 4종 생성 + 재검증 | ✅ 실측 (report/minutes/slides/spreadsheet) |
| python-docx 오프라인 설치(의존성 포함) | ✅ 실측 |
| 테마 스타일 적용(T Title 등) | ✅ 실측 |
| 템플릿 자동화 (fill_template.py, mock 데이터) | ✅ 실측 (3종 템플릿) |
| Open WebUI 등록 → 채팅 호출 → 다운로드 | ✅ 확인 완료 |

---

## 8. 템플릿 자동화 (fill_template.py)

채팅 없이 **CLI만으로 템플릿을 채운 문서를 생성**한다. 콘텐츠 템플릿(`tpl-*.md`)의
각 섹션을 더미(mock) 데이터로 채워 docx/pptx/md 파일을 만든다. 오프라인 환경 전용
도구이며 LLM 연동은 지원하지 않는다.

### 구조

```
tpl-*.md (콘텐츠 템플릿)     fill_template.py            결과 파일
┌──────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ frontmatter:     │     │ 1. 섹션 추출     │     │ .docx / .pptx   │
│   type: report   │ ──▶ │ 2. mock 데이터 채움│──▶ │ .md (검토용)     │
│   visual_theme   │     │ 3. 문서 조립     │     │                 │
│   instructions:  │     │                  │     │                 │
│ 섹션: 설명       │     │                  │     │                 │
│ {{섹션}} 자리표  │     │                  │     │                 │
└──────────────────┘     └──────────────────┘     └─────────────────┘
```

### 사용법

```bash
# 템플릿 목록
.venv/bin/python fill_template.py --list

.venv/bin/python fill_template.py tpl-report-quarterly.md --topic "2분기 운영"
```

### 기본 제공 템플릿

| 템플릿 | 종류 | 테마 | 섹션 |
| --- | --- | --- | --- |
| `tpl-report-quarterly.md` | report (docx) | default | 개요, 핵심 지표, 주요 이슈, 개선 과제, 향후 계획 |
| `tpl-proposal-tech.md` | report (docx) | corporate | 배경, 현황, 제안, 기대효과, 일정, 예산 |
| `tpl-briefing-slides.md` | slides (pptx) | default | 현황 요약, 성과, 이슈, 계획 |

### 새 템플릿 만들기

`document-templates/tpl-<이름>.md` 파일을 만들면 자동 인식:

```markdown
---
type: report              # report | minutes | slides
visual_theme: default      # theme-<이름>.docx 매칭
title: "문서 제목"
table_style: grid          # grid | plain | striped | minimal
instructions:
  섹션1: "이 섹션에 담길 내용 설명 (mock 데이터에 매칭되는 문서용 참고 메모)"
  섹션2: "표가 필요하면 표 형식임을 설명"
---

## 섹션1
{{섹션1}}

## 섹션2
{{섹션2}}
```
