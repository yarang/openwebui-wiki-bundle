# 시드 위키 — 설치 시 `~/llm-wiki/wiki`로 복사됩니다

이 디렉토리는 guardian 통합 번들의 **시드 위키**입니다.
첫 설치 때 설치 스크립트가 이 폴더 전체를 `~/llm-wiki/wiki`로 복사합니다.
이미 `~/llm-wiki/wiki`가 있으면 덮어쓰지 않습니다.

## 용도

- 설치 직후 빈 위키가 아니라, 바로 검색·탐색을 시험해 볼 수 있는 **데모 노트 3개**(`concepts/`, 허브 `index.md` 제외)를 담습니다.
- 노트 개수가 적어도 15개 도구(`search_wiki`, `read_note`, `create_note`, …)가 어떻게 동작하는지 바로 확인할 수 있습니다.
- 시드 내용은 지우고 실제 자료로 교체해도 됩니다. 노트를 정리한 뒤 `reindex` 도구를 호출하세요.
- `WIKI_PATH`를 지정하지 않고 `wiki-mcp`를 단독으로 실행할 때의 폴백은 이 폴더가 아니라 `wiki-mcp/examples/sample-wiki`입니다.

## 구조

```
wiki/
├── README.md                  # 이 파일 (노트 아님)
├── index.md                   # 허브 노트 (id: index)
├── concepts/
│   ├── welcome.md             # 시작 안내 노트 (id: welcome)
│   ├── sample-concept.md      # 원자 노트 예시 (id: sample-concept)
│   └── another-concept.md     # 두 번째 개념 (id: another-concept)
└── .templates/                # 노트 양식 (concept.md, guide.md)
```

## 노트 규칙 (요약)

- 각 노트는 YAML frontmatter로 시작하며 `id`, `title`, `tags`, `created_at`, `last_updated`를 포함합니다.
- `id`는 kebab-case 소문자 영문/숫자/하이픈만 허용합니다 (예: `sample-concept`).
- 노트 간 연결은 `[[id]]` 또는 `[[id|표시 텍스트]]` 형식의 위키링크를 사용합니다.
- `## 관련 노트` 섹션에 단방향 링크를 정리하는 것이 관례입니다.

전체 구성은 [`../docs/USAGE.md`의 "아키텍처 요약"](../docs/USAGE.md#아키텍처-요약) 절을 참고하세요.
