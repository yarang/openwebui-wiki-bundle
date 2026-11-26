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
cat > ./행사안내.md <<'EOF'
# 행사 안내
행사 일정과 장소를 알린다.
EOF
~/.claude/skills/hwpx/scripts/hwpx from-md ./행사안내.md
```

from-md 에는 md 경로 하나만 쓴다. 결과는 같은 이름의 .hwpx 파일로 생긴다(./행사안내.md → ./행사안내.hwpx).
읽기: ~/.claude/skills/hwpx/scripts/hwpx read ./파일.hwpx
양식: ~/.claude/skills/hwpx/scripts/hwpx fields ./양식.hwpx → 값을 ./값.json 에 저장(Bash heredoc) → ~/.claude/skills/hwpx/scripts/hwpx fill ./양식.hwpx ./값.json ./결과.hwpx
JSON 키는 fields 줄에서 '- ' 뒤부터 ' ← ' 앞까지를 그대로 복사한다(예: 성명 (표 0, 행 7)). ← 뒤는 그 칸이 어느 항목인지 알려 주는 설명이다.
사용자 말로 키를 지어내지 말고 fields 를 먼저 실행해, 사용자가 말한 항목을 ← 뒤 설명과 맞춰 그 줄의 키를 쓴다.
값은 문자열(정수 가능)로 쓰고, 'fill 불가' 가 붙은 줄은 넣지 않는다.
양식이 길면 fields 를 한 번만 실행하고 필요한 줄만 골라 쓴다.
출력 파일이 이미 있으면 거부되므로 다른 이름을 쓴다.
결과 첫 줄이 OK 면 그 경로를 사용자에게 알린다. ERROR 에 '다시 시도할 키' 가 있으면 ./값.json 의 그 키를 → 뒤 위치 키로 바꿔 저장하고 fill 을 다시 실행한다(출력 파일 이름은 새로). 그래도 ERROR 면 사유를 사용자에게 알린다.
자세한 옵션: ~/.claude/skills/hwpx/scripts/hwpx --help
