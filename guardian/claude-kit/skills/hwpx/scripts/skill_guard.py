#!/usr/bin/env python3
"""skill-guard 의 본체(bash 래퍼 skill-guard 가 stdin 의 hook JSON 을 넘긴다).

세 가지 일을 한다:
1. skill 되풀이 거부(PreToolUse·Skill): 세션마다 같은 skill 의 첫 호출은 허용하고 두 번째부터는 거부한다.
   Skill 은 SKILL.md 안내만 대화에 싣고 명령을 실행하지 않아 작은 모델이 같은 호출을 되풀이하기 때문이다.
   거부할 때는 Bash 로 실행할 명령을 이유에 적어 준다. 첫 호출을 허용할 때 명령 있는 skill 은 <세션>.pending
   표시를 남기고, 그 명령을 Bash 가 인자와 함께 실제로 돌리면 표시를 지운다.
2. 오피스 파일 거부(PreToolUse·Write/Edit/MultiEdit/Bash): docx xlsx pptx hwpx(옛 .doc .xls .ppt .hwp 포함)
   파일을 Write/Edit 이나 Bash 리다이렉트(> >> tee)·mv/cp 이름 바꾸기로 만들면 거부하고 from-md 명령을 알려 준다.
   이때 거부된 파일 이름이 안전한 모양이면 그 이름으로 명령을 보여 주고, 명령이 설치되어 있으면 표시도 남긴다.
3. Stop 가드(Stop): skill 안내를 읽고도 그 명령을 Bash 로 돌리지 않은 채 멈추면 최대 두 번 막고 원래 요청을
   끝내라고 한다. 표시 파일에는 차단 횟수와 파일 이름을 함께 적는다(횟수가 2 이상이면 표시를 지우고 허용).
   표시가 없을 때는 끝 답의 '만들었다' 주장을 검사한다: 주장한 오피스 파일(새 형식 네 확장자)이 실제로
   없으면 세션마다 한 번 막고 그 파일의 from-md 명령을 알려 준다(일반 파일의 앞 4바이트만 논블로킹으로
   읽는다). 물음·부정·만드는 방법 안내(…하려면 …하세요) 문장은 주장이 아니다.
4. 끝나지 않은 heredoc(PreToolUse·Bash): 닫는 구분자 줄이 혼자 한 줄이 아니면 명령이 끝까지 돌지 않으므로 거부한다.
5. from-md 결과 이름 검사(PreToolUse·Bash): <종류> from-md 의 결과 파일 이름(두 인자면 둘째, 한 인자면 md
   이름)이 마지막 사용자 요청의 같은 종류 이름과 하나도 같지 않으면(세션·종류마다 최대 두 번) 거부하고 바른
   명령을 알려 준다. 요청 이름이 모두 이미 있으면 from-md 가 덮어 쓰지 않으므로 허용한다.
판단에 필요한 무엇이 하나라도 확실하지 않으면 출력 없이 끝난다(허용).
"""
import contextlib
import fcntl
import json
import os
import re
import shlex
import stat
import sys
import time
import unicodedata
import urllib.parse

SID_RE = re.compile(r"[A-Za-z0-9_-]{1,128}")
SKILL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}")
CMD_RE = re.compile(r"[a-z][a-z-]*")
STEM_RE = re.compile(r"[^\W_][\w.-]{0,63}")
COUNT_RE = re.compile(r"[0-9]{1,3}")
SPECIAL_RE = re.compile(r"[;&|$`\\<>()]")
OFFICE_EXTS = ((".docx", "docx"), (".xlsx", "xlsx"), (".pptx", "pptx"), (".hwpx", "hwpx"),
               (".doc", "docx"), (".xls", "xlsx"), (".ppt", "pptx"), (".hwp", "hwpx"))
OFFICE_KINDS = ("docx", "xlsx", "pptx", "hwpx")
HELP_WORDS = ("--help", "-h", "help")
ASSIGN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
REDIR_SKIP = ("redir", "in", "herestring", "heredoc")
# from-md 피연산자에 있으면 결과 이름을 알 수 없는 글자(셸 확장·glob). NAME_INPUT_RE 는 그대로 명령에
# 옮겨 적어도 되는 입력 경로 모양(확장 글자·공백이 없는 낱말)이다.
FROM_MD_SKIP = "$`*?[{\\"
NAME_INPUT_RE = re.compile(r"[\w./-]+", re.UNICODE)
# 끝 답 주장 검사: 문장 나누기(구두점을 버리지 않아 물음을 가려냄)·주장 말·부정 말·조건·권유 말(만드는
# 방법 안내)·오피스 파일 이름(새 형식 네 가지만, 대소문자 무시). 확장자 바로 뒤가 ASCII 글자([A-Za-z0-9_])
# 나 .ASCII 글자이면(report.docx.md, report.docx_old) 이름이 아니다. \w 는 한글도 포함하므로 경계는 ASCII
# 로만 본다(조사가 바로 붙은 회의록.docx를 도 이름).
SENT_SPLIT_RE = re.compile(r"(\n+|\. |[。！?？])")
CLAIM_WORDS_RE = re.compile(r"생성|만들|저장|작성|완료|created|saved", re.IGNORECASE)
DENY_WORDS_RE = re.compile(r"못|않|실패|없|failed|could not|unable|\bnot\b|n't|\bnever\b", re.IGNORECASE)
SUGGEST_WORDS_RE = re.compile(r"려면|세요|십시오|to +(?:create|save|make|generate)|\bif\b", re.IGNORECASE)
CLAIM_EXTS = "(?:docx|xlsx|pptx|hwpx)"
CLAIM_TAIL = 20000  # 끝 답·사용자 요청 글에서 보는 끝쪽 글자 수 상한(마지막 주장은 끝에 있다)
# 이름 낱말은 낱말 첫머리에서만 시작한다(앞 부정 lookbehind: 이름 글자나 : 이 바로 앞에 있으면 낱말 중간이다.
# : 을 막아 https:// 의 //… 이 시작하지 못하게 한다). 낱말 길이 상한(255)으로 시작 위치마다 끝까지 되짚는
# 제곱 시간을 막는다. MD_LINK_RE 의 라벨·대상 길이 상한과 라벨에서 [ 를 뺀 것도 같은 이유다.
CLAIM_NAME_RE = re.compile(r"(?<![\w$~/.\-+:])[\w$~/.\-+]{1,255}\." + CLAIM_EXTS
                           + r"(?![A-Za-z0-9_])(?!\.[A-Za-z0-9])", re.IGNORECASE)
TICK_NAME_RE = re.compile(r"[\w$~/.\-+ ()]{1,255}\." + CLAIM_EXTS, re.IGNORECASE)
TICK_SPAN_RE = re.compile(r"`([^`\n]+)`")
MD_LINK_RE = re.compile(r"\[([^\[\]\n]{0,255})\]\(([^()\[\]\s]{0,255})\)")
URL_HEAD_RE = re.compile(r"[A-Za-z][A-Za-z0-9+.\-]*:|//")
QUESTION_MARKS = ("?", "？")


def parse_event(raw):
    """hook JSON 을 dict 로. JSON 이 아니거나 dict 가 아니면 None(허용)."""
    try:
        obj = json.loads(raw)
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def session_id(obj):
    """session_id 가 믿을 수 있는 모양이면 그 값, 아니면 None."""
    sid = obj.get("session_id")
    return sid if isinstance(sid, str) and SID_RE.fullmatch(sid) else None


def normalize_skill(skill):
    """/hwpx 와 hwpx 는 같은 skill. 쓸 수 있는 이름만 돌려준다."""
    name = skill[1:] if skill.startswith("/") else skill
    return name if SKILL_RE.fullmatch(name) else None


def make_state_dir(path):
    """새 상태 폴더를 700 으로 만든다. 실패하면 None."""
    try:
        os.mkdir(path, 0o700)
        os.chmod(path, 0o700)
    except OSError:
        return None
    return path


def state_dir(create=True):
    """${TMPDIR:-/tmp}/claude-lms-skill-guard-<uid>. 내 폴더(700)가 확실할 때만 돌려준다.

    create 가 False 면 이미 있는 폴더만 돌려준다(읽기만 하는 판단이 폴더를 새로 만들지 않게 한다)."""
    base = (os.environ.get("TMPDIR") or "/tmp").rstrip("/") or "/"
    path = "%s/claude-lms-skill-guard-%d" % (base, os.getuid())
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return make_state_dir(path) if create else None
    except OSError:
        return None
    mine = stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and stat.S_IMODE(st.st_mode) == 0o700
    return path if mine else None


def seen_before(path, name):
    """세션 파일에 이름이 이미 있으면 True. 처음이면 한 줄 적고 False. 못 열면 None(허용, 기록 없음)."""
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)
        handle = os.fdopen(fd, "r+", encoding="utf-8")
    except OSError:
        return None
    with handle:
        seen = name in handle.read().splitlines()
        if not seen:
            handle.write(name + "\n")
    return seen


def already_called(base, sid, name):
    """세션 파일에 name 이 적혀 있나만 본다(읽기 전용, 새로 적지 않는다). 못 열면 False."""
    path = os.path.join(base, sid)
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            return False
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return False
    with os.fdopen(fd, "r", encoding="utf-8", errors="replace") as h:
        return name in h.read().splitlines()


def pending_path(base, sid):
    """첫 호출 표시 파일(<세션>.pending)의 경로."""
    return os.path.join(base, sid + ".pending")


def set_pending(path, name, count=0, stem=""):
    """표시 파일(name 줄, 차단 횟수 줄, 파일 이름 줄)을 600 으로 안전하게 쓴다. 성공하면 True.

    자리가 심볼릭 링크 등 일반 파일이 아니면 쓰지 않고 False."""
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            return False
    except FileNotFoundError:
        pass
    except OSError:
        return False
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)
    except OSError:
        return False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as h:
            h.write("%s\n%d\n%s\n" % (name, count, stem))
        return True
    except OSError:
        return False


def read_pending(path):
    """표시 파일 내용을 (name, 차단 횟수, 파일 이름)으로. 없거나 심볼릭 링크·일반 파일이 아니거나 이름이
    못 쓴 모양이면 None. 횟수는 옛 형식(정확히 이름 한 줄)일 때만 0 이고, 여러 줄 기록에서 둘째 줄이
    숫자 1~3자리가 아니면 None(못 쓴 표시)."""
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            return None
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    with os.fdopen(fd, "r", encoding="utf-8", errors="replace") as h:
        lines = h.read().split("\n")
    name = lines[0].strip() if lines else ""
    if not SKILL_RE.fullmatch(name):
        return None
    count = _count_line(lines)
    stem = lines[2].strip() if len(lines) > 2 else ""
    return name, count, stem if stem and STEM_RE.fullmatch(stem) else ""


def _count_line(lines):
    """표시의 차단 횟수 줄을 읽는다. 옛 형식(이름 한 줄, 줄바꿈까지만)이면 0, 둘째 줄이 1~3자리 숫자면
    그 값, 그 밖(빈 횟수 줄·숫자 아님·자릿수 넘침)이면 None(못 쓴 표시)."""
    if lines[1:] in ([], [""]):
        return 0
    text = lines[1].strip()
    return int(text) if COUNT_RE.fullmatch(text) else None


def clear_pending(path):
    """표시를 지운다(unlink 는 심볼릭 링크를 따라가지 않는다). 지웠으면 True, 아니면 False."""
    try:
        os.unlink(path)
        return True
    except OSError:
        return False


def _open_lock(path):
    """잠금 파일(<세션>.lock)을 안전하게 열어 fd 를 돌려준다. 자리가 일반 파일이 아니거나 못 열리면 None.
    지우지 않는다(기다리는 다른 프로세스의 잠금을 깨뜨리므로)."""
    try:
        try:
            st = os.lstat(path)
            if not stat.S_ISREG(st.st_mode):
                return None
        except FileNotFoundError:
            pass
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)
        return fd
    except OSError:
        return None


@contextlib.contextmanager
def session_lock(base, sid):
    """표시 파일의 읽기→판단→쓰기(지우기)를 한 세션 안에서 서로 겹치지 않게 묶는 잠금.

    얻으면 True 를 넘겨 주고, 정해진 횟수 안에 못 얻으면 False(그대로 허용·기록 생략). 대기는
    잠긴 동안 다른 hook 가 표시를 고치는 찰나를 기다리는 것뿐이므로 오래 걸리지 않는다."""
    fd = _open_lock(os.path.join(base, sid + ".lock"))
    got = False
    if fd is not None:
        for _ in range(40):
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                got = True
                break
            except OSError:
                time.sleep(0.05)
    try:
        yield got
    finally:
        if fd is not None:
            try:
                if got:
                    fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
            os.close(fd)


def command_path(name):
    """~/.claude/skills/<이름>/scripts/<이름> 실행 파일이 확실할 때만 ~ 표기 경로를 돌려준다."""
    if ":" in name:
        return None
    home = os.environ.get("HOME", "")
    if not home:
        return None
    real = "%s/.claude/skills/%s/scripts/%s" % (home, name, name)
    try:
        st = os.stat(real)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode) or not st.st_mode & 0o111:
        return None
    return "~/.claude/skills/%s/scripts/%s" % (name, name)


def clean_args(args):
    """제어 문자(\x00-\x1f, \x7f)는 공백으로, 연속 공백은 한 칸, 앞뒤 공백 제거."""
    flat = "".join(" " if ord(c) < 0x20 or c == "\x7f" else c for c in args)
    return " ".join(flat.split())


def copyable(text):
    """정리한 args 를 명령에 그대로 옮겨도 안전한가(내용 있음·300자 이하·첫 낱말 모양·특수 문자 없음)."""
    first = text.split(" ")[0] if text else ""
    return bool(text) and len(text) <= 300 and bool(CMD_RE.fullmatch(first)) and not SPECIAL_RE.search(text)


def deny_reason(name, args, cmd):
    """거부 이유: 명령을 짜낼 수 있으면 그 명령을, 아니면 --help 나 일반 안내를 적는다."""
    if cmd:
        text = clean_args(args)
        if copyable(text):
            return "%s 안내는 이미 읽었습니다. Skill 을 다시 부르지 말고 Bash 로 실행하세요: %s %s" % (name, cmd, text)
        return ("%s 안내는 이미 읽었습니다. Skill 을 다시 부르지 말고 Bash 로 %s <명령> … 을 실행하세요"
                "(명령 목록: %s --help)") % (name, cmd, cmd)
    return "%s 안내는 이미 이 대화에 있습니다. Skill 을 다시 부르지 말고 그 안내대로 Bash 등 도구로 바로 실행하세요." % name


def office_type(target):
    """대상이 오피스 확장자(docx xlsx pptx hwpx, 옛 doc xls ppt hwp 포함)로 끝나면 그 형식을, 아니면 None."""
    name = target.rsplit("/", 1)[-1].lower()
    for ext, kind in OFFICE_EXTS:
        if name.endswith(ext):
            return kind
    return None


def safe_stem(path):
    """거부된 대상 경로에서 확장자를 뺀 파일 이름 부분. 공백·$·따옴표 등이 없는 안전한 모양일 때만 돌려준다."""
    if not isinstance(path, str):
        return None
    base = path.rsplit("/", 1)[-1]
    for ext, _kind in OFFICE_EXTS:
        if base.lower().endswith(ext):
            base = base[: -len(ext)]
            break
    return base if base and STEM_RE.fullmatch(base) else None


def _read_quote(s, i):
    """s[i] 가 ' 나 " 일 때 닫는 따옴표까지 읽어 (해석한 값, 다음 위치). 안 닫히면 (None, i)."""
    q = s[i]
    out = []
    i += 1
    while i < len(s):
        c = s[i]
        if c == q:
            return "".join(out), i + 1
        if q == '"' and c == "\\" and i + 1 < len(s) and s[i + 1] in '"\\$':
            out.append(s[i + 1])
            i += 2
        elif q == '"' and c == "\\" and i + 1 < len(s) and s[i + 1] == "\n":
            i += 2
        else:
            out.append(c)
            i += 1
    return None, i


ANSIC_ESC = {"\\": "\\", "'": "'", '"': '"', "n": "\n", "t": "\t", "r": "\r",
             "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
             "v": "\v", "?": "?"}


def _read_ansic(s, i):
    """s[i:i+2] 가 $' 일 때 ANSI-C 따옴표를 읽어 (해석한 값, 다음 위치, 해석 확실). \\' 은 닫는 따옴표가
    아니다. \\ \\' \\" \\n \\t \\r \\a \\b \\e \\E \\f \\v \\? 만 해석하고 그 밖(\\x \\u \\0nn \\c …)이
    있으면 확실을 깎는다. 닫는 ' 이 없으면 (None, i, False)."""
    out = []
    sure = True
    i += 2
    while i < len(s):
        c = s[i]
        if c == "'":
            return "".join(out), i + 1, sure
        if c == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            out.append(ANSIC_ESC.get(nxt, nxt))
            if nxt not in ANSIC_ESC:
                sure = False
            i += 2
        else:
            out.append(c)
            i += 1
    return None, i, False


def _fd_dup_end(s, i):
    """s[i] 는 >& 바로 다음. 이어지는 낱말(앞의 공백 건너뜀)이 모두 숫자이거나 - 이면 fd 중복이라 (True, 낱말 끝 위치),
    아니면 (False, i). >& 뒤가 파일 이름이면 dup 이 아니라 파일 쓰기(&> 와 같음)다."""
    j = i
    while j < len(s) and s[j] in " \t":
        j += 1
    e = j
    while e < len(s) and s[e] not in " \t\n'\"\\;&|<>()":
        e += 1
    word = s[j:e]
    return (True, e) if word and (word.isdigit() or word == "-") else (False, i)


def _read_op(s, i):
    """s[i] 의 연산자를 읽어 (종류, 값, 다음 위치). 종류: op(명령 구분) redir(대상 파일) dup(fd 중복) in heredoc herestring."""
    c = s[i]
    if c == "&":
        if s.startswith("&>>", i):
            return "redir", "&>>", i + 3
        if s.startswith("&>", i):
            return "redir", "&>", i + 2
        if s.startswith("&&", i):
            return "op", "&&", i + 2
        return "op", "&", i + 1
    if c == "|":
        if s.startswith("||", i):
            return "op", "||", i + 2
        return "op", "|", i + 1
    if c in ";()":
        return "op", c, i + 1
    if c == "<":
        if s.startswith("<<<", i):
            return "herestring", "<<<", i + 3
        if s.startswith("<<-", i):
            return "heredoc", "<<-", i + 3
        if s.startswith("<<", i):
            return "heredoc", "<<", i + 2
        return "in", "<", i + 1
    if s.startswith(">>", i):
        kind, j = ">>", i + 2
    elif s.startswith(">|", i):
        kind, j = ">|", i + 2
    else:
        kind, j = ">", i + 1
    if j < len(s) and s[j] == "&":  # 2>&1 >&2 >&- 는 fd 중복, >& 파일이름은 &> 처럼 파일 쓰기다
        fd, end = _fd_dup_end(s, j + 1)
        if fd:
            return "dup", kind + "&", end
        return "redir", kind + "&", j + 1
    return "redir", kind, j


def _odd_backslashes(line):
    """줄이 홀수 개의 역슬래시로 끝나나(따옴표 없는 heredoc 본문의 줄 잇기 여부)."""
    k = 0
    while k < len(line) and line[-1 - k] == "\\":
        k += 1
    return k % 2 == 1


def _heredoc_line(s, i, quoted):
    """본문의 논리 줄 하나를 읽어 (줄, 다음 위치, 끝에 닿았나). 따옴표 없는 구분자일 때만 줄 잇기를
    적용한다: 줄이 홀수 개의 역슬래시로 끝나면 마지막 역슬래시와 줄바꿈을 지우고 다음 줄과 잇는다."""
    j = s.find("\n", i)
    line = s[i:] if j < 0 else s[i:j]
    i = len(s) if j < 0 else j + 1
    end = j < 0
    while not quoted and not end and _odd_backslashes(line):
        k = s.find("\n", i)
        line = line[:-1] + (s[i:] if k < 0 else s[i:k])
        i = len(s) if k < 0 else k + 1
        end = k < 0
    return line, i, end


def _skip_heredocs(s, i, delims):
    """줄바꿈 다음 위치 i 부터 heredoc 본문 줄들을 차례로 건너뛴다. (다음 위치, 닫지 못한 구분자 목록).
    <<- 는 논리 줄의 앞 탭을 무시하고 비교한다."""
    miss = []
    for delim, tabs, quoted, _unsure in delims:
        while True:
            line, i, end = _heredoc_line(s, i, quoted)
            if (line.lstrip("\t") if tabs else line) == delim:
                break
            if end:
                miss.append(delim)
                break
    return i, miss


def shell_words(command):
    """셸 명령을 한 글자씩 읽어 (토큰 목록, 확실한가, 닫히지 않은 heredoc 구분자 목록)으로.

    토큰은 ("word", 따옴표·역슬래시·$'…' 를 적용한 값) 또는 (종류, 값). 종류는 op(줄바꿈 ; && || | & ( ))
    redir dup in heredoc herestring. 따옴표 안은 절대 연산자·주석이 되지 않고, heredoc 본문은 읽지 않고
    건너뛴다. heredoc 는 ( ) ·$( ) ·{ } 안에서도 top level 과 똑같이 세고(본문을 명령으로 읽지 않는다),
    산술 자리(( expr )) ·$(( expr )) 안의 << 만 heredoc 로 세지 않는다(이동 연산자). $'…' 는 ANSI-C
    따옴표, $"…" 는 "…" 로 해석하고, 해석 못 하는 이스케이프가 있으면 sure 가 False 다. 따옴표가 안
    닫히면 sure 가 False 가 되고, heredoc 구분자의 닫는 줄을 끝내 못 찾으면 그 구분자가 unclosed 에
    든다(구분자 낱말이 확실하지 않으면 나머지를 본문으로 보아 unclosed 에 넣지 않는다)."""
    s = command
    n = len(s)
    tokens = []
    delims = []   # 이 줄의 heredoc [(구분자, 탭 무시, 따옴표 친 구분자, 확실)], 구분자는 << 뒤 낱말로 채운다
    unclosed = []
    sure = True
    arith = None  # (( 로 시작한 산술 자리의 열린 ( 개수: 안쪽의 << 는 이동 연산자다
    parts = []
    started = False
    plain = True    # 낱말이 따옴표·역슬래시 없이만 이어졌나(바로 앞 숫자를 fd 번호로 볼지)
    unsure = False  # 지금 낱말에 해석 못 하는 부분($'…' 의 특수 이스케이프)이 있나

    def flush():
        nonlocal started, plain, unsure
        if started:
            value = "".join(parts)
            tokens.append(("word", value))
            if delims and delims[-1][0] is None:
                delims[-1] = (value, delims[-1][1], not plain, unsure)
        del parts[:]
        started = False
        plain = True
        unsure = False

    i = 0
    while i < n:
        c = s[i]
        if c in " \t":
            flush()
            i += 1
        elif c == "\n":
            flush()
            tokens.append(("op", "\n"))
            i += 1
            if delims:
                if any(d[3] for d in delims):
                    i, sure = n, False  # 구분자를 못 알면 나머지 전부를 본문으로 본다(허용)
                else:
                    i, miss = _skip_heredocs(s, i, delims)
                    unclosed.extend(miss)
                    sure = sure and not miss
                del delims[:]
        elif c == "#" and not started:
            j = s.find("\n", i)
            i = n if j < 0 else j
        elif c == "$" and i + 1 < n and s[i + 1] in "'\"":
            if s[i + 1] == "'":
                text, j, ok = _read_ansic(s, i)
                if text is None:
                    return tokens, False, unclosed
                if not ok:
                    sure, unsure = False, True  # 해석 못 함 → 아무것도 지우지 않는다
            else:  # $"…" (로케일 따옴표) 는 "…" 와 같다
                text, j = _read_quote(s, i + 1)
                if text is None:
                    return tokens, False, unclosed
            parts.append(text)
            started, plain = True, False
            i = j
        elif c in "'\"":
            text, j = _read_quote(s, i)
            if text is None:
                return tokens, False, unclosed
            parts.append(text)
            started, plain = True, False
            i = j
        elif c == "\\":
            if i + 1 >= n:
                return tokens, False, unclosed
            if s[i + 1] != "\n":  # 줄 잇기(\\+줄바꿈)가 아니면 이스케이프
                parts.append(s[i + 1])
                started, plain = True, False
            i += 2
        elif c in ";&|<>()":
            if c == ">" and started and plain and "".join(parts).isdigit():
                started, plain = False, True  # 낱말 전체가 숫자 → fd 번호로 흡수(1> 2>>)
                del parts[:]
            else:
                flush()
            kind, val, i = _read_op(s, i)
            tokens.append((kind, val))
            if val == "(" and arith is None and i < n and s[i] == "(":
                tokens.append(("op", "("))  # (( ·$(( : 두 ( 사이에 아무것도 없으면 산술 자리 시작
                arith = 1
                i += 1
            elif arith is not None:
                if c == "(":
                    arith += 1
                elif c == ")":
                    arith -= 1
                    if arith <= 0:
                        arith = None
            if kind == "heredoc" and arith is None:
                delims.append((None, val == "<<-", False, False))
        else:
            parts.append(c)
            started = True
            i += 1
    flush()
    if any(d[3] for d in delims):
        sure = False
    unclosed.extend(d for d, _t, _q, u in delims if not u)
    return tokens, sure, unclosed


def simple_commands(tokens):
    """토큰을 명령 구분 연산자(op) 기준으로 나눠 simple command 토큰 목록들의 목록으로."""
    cmds = []
    cur = []
    for tok in tokens:
        if tok[0] == "op":
            if cur:
                cmds.append(cur)
            cur = []
        else:
            cur.append(tok)
    if cur:
        cmds.append(cur)
    return cmds


def command_parts(cmd):
    """simple command 하나에서 (명령 낱말, 나머지 낱말들). NAME=값 접두와 리다이렉트 대상 낱말은 뺀다."""
    words = []
    skip = False
    for kind, val in cmd:
        if kind == "word":
            if skip:
                skip = False
            else:
                words.append(val)
        elif kind in REDIR_SKIP:
            skip = True
    head = None
    rest = []
    for w in words:
        if head is None and ASSIGN_RE.match(w):
            continue
        if head is None:
            head = w
        else:
            rest.append(w)
    return head, rest


def operand_words(rest):
    """명령 낱말 뒤 낱말들에서 옵션(-…)을 빼고 대상만 남긴다. -- 뒤의 낱말은 모두 대상이다."""
    out = []
    files_only = False
    for w in rest:
        if files_only:
            out.append(w)
        elif w == "--":
            files_only = True
        elif not w.startswith("-"):
            out.append(w)
    return out


def redirect_office(tokens):
    """redir(> >> >| &> &>> >&파일 N> N>> — dup(>&2 등) 제외) 바로 다음 낱말이 오피스 파일이면 (형식, 그 경로)."""
    for pos, (kind, _val) in enumerate(tokens):
        if kind == "redir" and pos + 1 < len(tokens) and tokens[pos + 1][0] == "word":
            got = office_type(tokens[pos + 1][1])
            if got:
                return got, tokens[pos + 1][1]
    return None


def command_base(word):
    """명령 낱말의 마지막 / 뒤 부분(/bin/cp → cp)만 본다. None 은 그대로."""
    return word.rsplit("/", 1)[-1] if word else word


def bash_office_type(tokens):
    """simple command 들을 봐서 tee·mv/cp(절대 경로 /bin/cp 모양 포함)로 오피스 파일을 만들면 (형식, how, 그 경로)."""
    for cmd in simple_commands(tokens):
        head, rest = command_parts(cmd)
        name = command_base(head)
        if name == "tee":
            for w in operand_words(rest):
                got = office_type(w)
                if got:
                    return got, "Bash 리다이렉트(> >> tee)", w
        elif name in ("mv", "cp"):
            operands = operand_words(rest)
            if len(operands) >= 2:
                got = office_type(operands[-1])
                if got and any(not office_type(w) for w in operands[:-1]):
                    return got, "mv/cp 이름 바꾸기", operands[-1]
    return None


def runs_skill_script(tokens, name):
    """어떤 simple command 의 명령 낱말이 skills/<이름>/scripts/<이름> 로 끝나고, 그 다음 낱말이
    --help/-h/help 가 아니면(인자와 함께 돌리면) True."""
    suffix = "/skills/%s/scripts/%s" % (name, name)
    for cmd in simple_commands(tokens):
        head, rest = command_parts(cmd)
        if head is not None and head.endswith(suffix) and rest and rest[0] not in HELP_WORDS:
            return True
    return False


def deny_json(reason):
    """PreToolUse 거부 출력 한 줄."""
    out = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                  "permissionDecisionReason": reason}}
    return json.dumps(out, ensure_ascii=False)


def from_md_cmd(cmd, kind, stem):
    """from-md 명령 줄과 덧붙일 안내(출력 경로는 명령이 알아서 정한다). stem 이 안전하면 그 이름으로,
    아니면 ./이름 과 사용자 이름 안내."""
    if stem:
        return "%s from-md ./%s.md" % (cmd, stem), ""
    return "%s from-md ./이름.md" % cmd, " 이름 자리에는 사용자가 말한 파일 이름을 쓰세요."


def office_reason(kind, called, cmd, how, stem):
    """오피스 파일을 글자로 만들려 할 때의 거부 이유. cmd 가 없으면 경로를 지어내지 않는다."""
    head = "[skill-guard] %s 로 %s 파일을 만들면 오피스에서 못 여는 글자 파일이 됩니다." % (how, kind)
    if not cmd:
        return "%s Skill %s 를 부르고 안내에 따라 Bash 로 만드세요." % (head, kind)
    form, tail = from_md_cmd(cmd, kind, stem)
    if called:
        return "%s Skill 을 다시 부르지 말고 Bash heredoc 로 Markdown 을 저장한 뒤 %s 로 만드세요.%s" % (head, form, tail)
    return "%s Skill %s 를 부르고 Bash heredoc 로 Markdown 을 저장한 뒤 %s 로 만드세요.%s" % (head, kind, form, tail)


def heredoc_reason(delim):
    """끝나지 않은 heredoc 거부 이유: 닫는 구분자 줄은 혼자 한 줄, 다음 명령은 그 다음 줄."""
    word = delim if delim and STEM_RE.fullmatch(delim) else "MD"
    return ("[skill-guard] heredoc 가 닫히지 않아 이 명령은 끝까지 돌지 않습니다. 끝을 알리는 %s 줄은 다른 글자 "
            "없이 혼자 한 줄이어야 합니다(%s && 처럼 붙이면 안 됨). 변환 명령은 그 다음 줄에 쓰세요.\n"
            "cat > ./이름.md <<'%s'\n본문\n%s" % (word, word, word, word))


def stop_reason(name, cmd, count, stem, called):
    """Stop 차단 이유: 첫 차단은 원래 요청을 Bash 도구로 끝내라고 자세히, 두 번째는 같은 요지로 짧게."""
    if name in OFFICE_KINDS:
        form, tail = from_md_cmd(cmd, name, stem)
        act = "Markdown 을 Bash heredoc 로 저장한 뒤 %s 로 변환하세요." % form
    else:
        form, tail = "%s --help" % cmd, ""
        act = "%s 로 명령 목록을 보고 알맞은 명령을 고르세요." % form
    if count:
        return "[skill-guard] 아직 파일이 없습니다. 이번 답은 글이 아니라 Bash 도구 호출이어야 합니다: %s%s" % (form, tail)
    known = "%s 안내는 이미 읽었습니다. " % name if called else ""
    again = " Skill 을 다시 부르지 말고," if called else ""
    return ("[skill-guard] %s요청한 파일이 아직 없습니다. 이번 답은 글이 아니라 Bash 도구 호출로 원래 요청대로 "
            "끝내세요.%s %s 사용자가 준 내용만 쓰고 수치·이름·날짜를 지어내지 않는다.%s" % (known, again, act, tail))


def _sentences(text):
    """끝 답을 (문장, 끝 구두점) 묶음으로 나눈다(줄바꿈, '. ', '。', '!', '?'). 구두점을 버리지 않아
    '?' 나 '？' 로 끝난 문장이 물음인지 알 수 있다."""
    parts = SENT_SPLIT_RE.split(text)
    out = []
    for i in range(1, len(parts), 2):
        if parts[i - 1].strip():
            out.append((parts[i - 1], parts[i]))
    if len(parts) % 2 and parts[-1].strip():
        out.append((parts[-1], ""))
    return out


def _claim_target(name, cwd):
    """주장한 파일 이름을 실제 경로로. ~/ 는 HOME 기준, 절대 경로는 그대로, 상대 이름은 cwd 기준."""
    if name.startswith("~"):
        home = os.environ.get("HOME", "")
        if home:
            return os.path.join(home, name[1:].lstrip("/"))
    return name if name.startswith("/") else os.path.join(cwd, name)


def _claim_present(name, cwd):
    """주장한 파일이 실재(zip 머리)하는지. / 바로 아래 이름 하나(/계획.pptx)는 모델이 cwd 파일 이름에 / 를
    붙여 쓴 것이 흔하므로 그 절대 경로나 cwd 기준 경로(os.path.join(cwd, 이름[1:])) 중 하나만 있어도 있는
    것이다. 더 깊은 절대 경로는 그 절대 경로만 본다."""
    if name.startswith("/") and os.path.dirname(name) == "/":
        return _is_zip_head(name) or _is_zip_head(os.path.join(cwd, name[1:]))
    return _is_zip_head(_claim_target(name, cwd))


def _is_zip_head(path):
    """대상이 일반 파일이고 앞 4바이트가 zip 머리(PK\x03\x04)인지만 본다. 논블로킹으로 열어 FIFO 나 장치
    파일에서 멈추지 않고, 일반 파일이 아니면 없는 것으로 본다(심볼릭 링크는 대상이 일반 파일일 때 따라간다)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return False
            return os.read(fd, 4) == b"PK\x03\x04"
        finally:
            os.close(fd)
    except OSError:
        return False


def _claim_kind(name):
    """주장한 이름의 오피스 형식. 새 형식(docx xlsx pptx hwpx)일 때만 그 형식을, 아니면 None."""
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    return ext if ext in OFFICE_KINDS else None


def _link_name(target):
    """Markdown 링크 대상을 이름으로 쓸 수 있으면 %표기(%20 등)를 푼(urllib.parse.unquote) 대상, 아니면
    None. 웹 주소(스킴 뒤 : 이나 // 로 시작)는 로컬 파일 주장이 아니고, 오피스 확장자로 끝나지 않는 대상도
    이름이 아니다(모양이 어긋난 대상을 잘라 쓰면 엉뚱한 이름이 되므로 통째로 버린다)."""
    plain = urllib.parse.unquote(target)
    if URL_HEAD_RE.match(plain) or not re.search(r"\." + CLAIM_EXTS + r"$", plain, re.IGNORECASE):
        return None
    return plain


def _claim_names(sent):
    """문장에서 주장할 수 있는 오피스 파일 이름(새 형식)을 나타난 순서로 뽑는다.
    백틱 `...` 안 전체가 이름이면 띄어쓰기·괄호 포함 그 전체를 한 이름으로, Markdown 링크 [라벨](대상) 은
    대상만 이름으로 본다(라벨은 버린다). 대상은 %표기를 풀어 쓰되 웹 주소거나 이름 모양이 아니면 링크 전체를
    지운다. 확장자 바로 뒤가 ASCII 글자나 .ASCII 글자이면(report.docx.md) 이름이 아니다(한글 조사가 바로
    붙은 회의록.docx를 도 이름)."""
    names = []

    def link_out(m):
        got = _link_name(m.group(2))
        if got:
            names.append(got)
        return " "

    text = MD_LINK_RE.sub(link_out, sent)
    rest = []
    pos = 0
    for m in TICK_SPAN_RE.finditer(text):
        inner = m.group(1).strip()
        if TICK_NAME_RE.fullmatch(inner):
            names.append(inner)
            rest.append(text[pos:m.start()] + " ")
            pos = m.end()
    rest.append(text[pos:])
    names.extend(m.group(0) for m in CLAIM_NAME_RE.finditer("".join(rest)))
    return names


def missing_claimed_files(message, cwd):
    """끝 답의 문장들에서 '만들었다'고 주장한 오피스 파일(새 형식) 중 실제로 없는(zip 머리가 아닌) 것을
    (이름, 형식)으로. 끝 답이 너무 길면 끝쪽 CLAIM_TAIL 자만 본다(마지막 주장은 끝에 있다).

    주장 말·부정 말·조건·권유 말 모두 파일 이름을 지운 나머지에서 본다(이름에만 든 created.docx · saved.xlsx
    같은 글자가 주장 말이 되는 일을 막는다). 같은 문장에 부정 말(경로 안의 '없는폴더' 같은 글자 포함)이나
    조건·권유 말(만드는 방법 안내)이 있으면 주장이 아니다. '?'(및 '？') 로 끝난 물음 문장도 주장이 아니다."""
    missing = []
    seen = set()
    for sent, mark in _sentences(message[-CLAIM_TAIL:]):
        if mark in QUESTION_MARKS:
            continue
        names = _claim_names(sent)
        if not names:
            continue
        rest = sent
        for name in names:
            rest = rest.replace(name, " ")
        if not CLAIM_WORDS_RE.search(rest) or DENY_WORDS_RE.search(rest) or SUGGEST_WORDS_RE.search(rest):
            continue
        for name in names:
            kind = _claim_kind(name)
            if kind and name not in seen and not _claim_present(name, cwd):
                seen.add(name)
                missing.append((name, kind))
    return missing


def claim_reason(missing):
    """끝 답 주장 검사의 차단 이유: 빠진 파일마다 그 이름의 from-md 명령(한 인자)을 준다."""
    parts = []
    for name, kind in missing:
        form, tail = from_md_cmd(command_path(kind), kind, safe_stem(name))
        parts.append("답에서 만들었다고 한 %s 파일이 아직 없습니다. "
                     "이번 답에서 Bash 도구로 Markdown 을 heredoc 로 저장하고 %s 를 실행하세요.%s" % (name, form, tail))
    return "[skill-guard] %s만들 수 없으면 만들지 못했다고 사실대로 말하세요." % " ".join(parts)


def _stem_from_prompt(prompt, kind):
    """사용자 요청 글의 끝쪽 CLAIM_TAIL 자에서 표시 종류와 같은 확장자의 파일 이름(CLAIM_NAME_RE 와 같은
    규칙)을 나타난 순서로 찾는다. 조사·따옴표·괄호가 이름에 붙어도 확장자 뒤가 ASCII 글자가 아니면 이름이고,
    safe_stem 을 통과한 첫 이름의 stem 을 돌려준다."""
    for m in CLAIM_NAME_RE.finditer(prompt[-CLAIM_TAIL:]):
        name = m.group(0)
        if name.lower().endswith("." + kind):
            stem = safe_stem(name)
            if stem:
                return stem
    return ""


def _requested_stems(tail, kind):
    """NFC 로 정리한 사용자 요청 글의 끝쪽 CLAIM_TAIL 자에서 그 종류 확장자의 파일 이름(CLAIM_NAME_RE 와
    같은 규칙)을 모두 찾아 safe_stem 을 통과한 stem 들을 나타난 순서로(겹치지 않게) 돌려준다."""
    stems = []
    for m in CLAIM_NAME_RE.finditer(tail):
        name = m.group(0)
        if name.lower().endswith("." + kind):
            stem = safe_stem(name)
            if stem and stem not in stems:
                stems.append(stem)
    return stems


def _read_file_tail(path, limit):
    """일반 파일의 끝 limit 바이트를 논블로킹으로 읽어 돌려준다. 일반 파일이 아니거나 못 열리면 None.
    limit 보다 큰 파일은 끝-limit 에서 읽고 잘린 첫 줄은 버린다(한 번의 readline/read 로 limit 를
    넘어 읽는 일이 없게 os.read 를 조금씩 반복한다)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None
        start = max(0, st.st_size - limit)
        os.lseek(fd, start, os.SEEK_SET)
        chunks = []
        total = 0
        while total < limit:
            chunk = os.read(fd, min(1 << 16, limit - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        data = b"".join(chunks)
        if start > 0:
            cut = data.find(b"\n")
            data = data[cut + 1:] if cut >= 0 else b""
        return data
    except OSError:
        return None
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def _last_prompt(obj):
    """대화 기록(transcript) 끝에서 마지막 사용자 요청(last-prompt)의 글을 얻는다. 큰 기록은 끝의 4MB 만
    읽고(잘린 첫 줄은 버린다), 깨진 JSON 줄은 건너뛴다. 일반 파일이 아니면(FIFO 멈춤 없이) None. 옛
    last-prompt 는 보지 않고, lastPrompt 가 글자가 아니면 None."""
    path = obj.get("transcript_path")
    if not isinstance(path, str):
        return None
    data = _read_file_tail(path, 4 * 1024 * 1024)
    if data is None:
        return None
    for raw in reversed(data.split(b"\n")):
        line = raw.strip()
        if not line or len(line) > 1024 * 1024:  # 큰 api-request-blob 줄은 last-prompt 가 아니다
            continue
        try:
            rec = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            continue
        if isinstance(rec, dict) and rec.get("type") == "last-prompt":
            prompt = rec.get("lastPrompt")
            return prompt if isinstance(prompt, str) else None
    return None


def transcript_stem(obj, kind):
    """대화 기록(transcript) 끝에서 마지막 사용자 요청(last-prompt)을 찾아 그 종류의 파일 이름 부분을 얻는다.
    큰 기록은 끝의 4MB 만 읽고(잘린 첫 줄은 버린다), 깨진 JSON 줄은 건너뛴다. 옛 last-prompt 는 보지 않는다."""
    if kind not in OFFICE_KINDS:
        return ""
    prompt = _last_prompt(obj)
    return _stem_from_prompt(prompt, kind) if prompt is not None else ""


def _from_md_kind(head):
    """명령 낱말이 skills/<종류>/scripts/<종류> 실행 경로로 끝나면 그 종류(docx xlsx pptx hwpx)."""
    if not head:
        return None
    for kind in OFFICE_KINDS:
        if head.endswith("/skills/%s/scripts/%s" % (kind, kind)):
            return kind
    return None


def _operand_stem(word, ext):
    """from-md 피연산자에서 결과 이름(stem)을 얻는다: basename 에서 확장자를 뺀다(ext 가 대소문자 무시로
    붙었으면 그것을, 다른 확장자가 있으면 마지막 확장자를). 확장 글자($ ` * ? [ { \\)가 있으면 이름을 알 수
    없으므로 None, 이름이 빈 이름이어도 None."""
    if not word or any(c in word for c in FROM_MD_SKIP):
        return None
    base = word.rsplit("/", 1)[-1]
    if base.lower().endswith("." + ext):
        base = base[: -(len(ext) + 1)]
    elif "." in base:
        base = base.rsplit(".", 1)[0]
    return base or None


def from_md_names(tokens):
    """from-md simple command 들을 (종류, 입력 피연산자, 결과 이름 stem)으로 나타난 순서로 돌려준다.
    결과 이름을 알 수 없는 명령(대상 없음·확장 글자)은 빠진다."""
    found = []
    for cmd in simple_commands(tokens):
        head, rest = command_parts(cmd)
        kind = _from_md_kind(head)
        if kind is None or not rest or rest[0] != "from-md":
            continue
        operands = operand_words(rest[1:])
        if not operands:
            continue
        two = len(operands) >= 2  # 두 인자면 결과는 둘째, 한 인자면 결과 이름은 md 이름에서 온다
        if two and any(c in operands[0] for c in FROM_MD_SKIP):
            continue  # 입력 md 에 확장 글자가 있으면 실제 경로를 알 수 없어 안내를 만들 수 없다 → 막지 않는다
        stem = _operand_stem(operands[1] if two else operands[0], kind if two else "md")
        if stem:
            found.append((kind, operands[0], stem))
    return found


def _name_matches(stem, stems, kind, tail):
    """결과 이름이 사용자 요청 이름과 같은가: 요청 stem 가운데 하나와 같거나, 요청 글 끝에 <결과 이름>.<종류>가
    다른 낱말과 붙지 않고 그대로 나오면 같다. 공백 든 이름은 CLAIM_NAME_RE 가 못 잡으므로 이 규칙으로 본다."""
    mine = unicodedata.normalize("NFC", stem)
    if mine in stems:
        return True
    pat = re.compile(r"(?<![\w.\-+])" + re.escape(mine) + r"\." + kind + r"(?![A-Za-z0-9])", re.IGNORECASE)
    return bool(pat.search(tail))


def _wrote_input(tokens, inp):
    """같은 Bash 명령 안의 리다이렉트(redir 바로 다음 낱말)가 from-md 의 입력 md 파일을 쓰고 있는가.
    앞의 ./ 표기는 빼고 견준다."""
    want = inp[2:] if inp.startswith("./") else inp
    for pos, (kind, _val) in enumerate(tokens):
        if kind == "redir" and pos + 1 < len(tokens) and tokens[pos + 1][0] == "word":
            got = tokens[pos + 1][1]
            if (got[2:] if got.startswith("./") else got) == want:
                return True
    return False


def _name_deny_reason(kind, cmd, inp, stem, candidates, wrote):
    """이름 거부 이유: 사용자가 요청한 이름(후보 전부)과 다르다고 하고, 같은 Bash 명령이 md 를 썼으면 이름 두
    곳을 바꾼 두 줄 예시를, 아니면 두 인자 명령을 정확히 준다(입력 경로가 NAME_INPUT_RE 에 안 끼면 빈칸 때문에
    셸 낱말이 갈라지지 않도록 shlex.quote 로 감싼다). 후보가 여럿이면 다른 이름 안내를 더한다(두 줄 예시는 두
    곳의 이름 자리를, 두 인자 안내는 결과 이름 자리를 말한다)."""
    names = ", ".join("./%s.%s" % (s, kind) for s in candidates)
    head = "[skill-guard] 결과 파일 이름(%s.%s)이 사용자가 요청한 이름(%s)과 다릅니다." % (stem, kind, names)
    if wrote:
        other = " 다른 이름이면 두 곳의 %s 자리에 그 이름(확장자 없이)을 쓰세요." % candidates[0] if len(candidates) > 1 else ""
        return ("%s%s 같은 Bash 명령을 이름 두 곳을 모두 바꿔 다시 보내세요:\n"
                "cat > ./%s.md <<'MD'\n%s from-md ./%s.md" % (head, other, candidates[0], cmd, candidates[0]))
    other = " 다른 이름이면 ./%s.%s 자리에 그 이름을 쓰세요." % (candidates[0], kind) if len(candidates) > 1 else ""
    given = inp if NAME_INPUT_RE.fullmatch(inp) else shlex.quote(inp)
    return "%s%s 사용자가 말한 이름으로 만드세요: %s from-md %s ./%s.%s" % (head, other, cmd, given, candidates[0], kind)


def _bump_name_deny(path):
    """이름 거부 횟수 파일(숫자만)을 읽어 2 미만이면 하나 늘려 적고 True(거부), 2 이상이거나 못 열리면
    False(허용). 못 쓴 내용은 0 으로 본다."""
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "r+", encoding="utf-8") as h:
            text = h.read().strip()
            count = int(text) if COUNT_RE.fullmatch(text) else 0
            if count >= 2:
                return False
            h.seek(0)
            h.truncate()
            h.write("%d" % (count + 1))
        return True
    except OSError:
        return False


def _from_md_name_deny(obj, tokens, kind, inp, stem, tail, cwd):
    """from-md 하나가 결과 이름을 요청과 다르게 쓰고 있는가: 거부 JSON 또는 None(이상 없음·허용). 요청한
    이름이 모두 이미 cwd 에 있으면 from-md 가 덮어 쓰지 않아 막다른 길이므로 허용한다."""
    stems = _requested_stems(tail, kind)
    if not stems or _name_matches(stem, stems, kind, tail):
        return None
    if not isinstance(cwd, str) or not os.path.isdir(cwd):
        return None
    missing = [s for s in stems if not os.path.lexists(os.path.join(cwd, "%s.%s" % (s, kind)))]
    if not missing:
        return None
    cmd = command_path(kind)
    if cmd is None:
        return None
    return _counted_name_deny(obj, tokens, kind, cmd, inp, stem, missing or stems)


def _counted_name_deny(obj, tokens, kind, cmd, inp, stem, candidates):
    """이름 거부를 세션·종류마다 최대 두 번까지 남긴다(<세션>.name-<종류> 횟수 파일). 잠금이나 상태 폴더가
    확실하지 않으면 허용한다."""
    reason = _name_deny_reason(kind, cmd, inp, stem, candidates, _wrote_input(tokens, inp))
    sid = session_id(obj)
    base = state_dir(True) if sid else None
    if base is None:
        return None
    path = os.path.join(base, "%s.name-%s" % (sid, kind))
    with session_lock(base, sid) as got:
        if not got or not _bump_name_deny(path):
            return None
    return deny_json(reason)


def from_md_name_block(obj, tokens):
    """from-md 결과 이름 검사(PreToolUse·Bash): 결과 파일 이름(두 인자면 둘째, 한 인자면 md 이름)이 마지막
    사용자 요청의 같은 종류 이름들과 하나도 같지 않으면 거부하고 바른 명령을 알려 준다. 대화 기록·cwd 가
    확실하지 않으면 허용하고, 표시(.pending)는 만들지도 지우지도 않는다. 예외가 나면 허용한다(hook 이
    결코 죽지 않게)."""
    try:
        found = from_md_names(tokens)
        prompt = _last_prompt(obj) if found else None
        if prompt is None:
            return None
        tail = unicodedata.normalize("NFC", prompt)[-CLAIM_TAIL:]
        cwd = obj.get("cwd")
        for kind, inp, stem in found:
            out = _from_md_name_deny(obj, tokens, kind, inp, stem, tail, cwd)
            if out is not None:
                return out
    except Exception:
        return None
    return None


def handle_skill(obj, tool_input):
    """첫 Skill 호출은 허용하며 명령 있는 skill 은 표시를 남긴다. 되풀이는 거부한다(표시는 안 남긴다)."""
    sid = session_id(obj)
    skill = tool_input.get("skill")
    if sid is None or not isinstance(skill, str):
        return None
    args = tool_input.get("args")
    name = normalize_skill(skill)
    if name is None:
        return None
    base = state_dir()
    if base is None:
        return None
    seen = seen_before(os.path.join(base, sid), name)
    if seen is True:
        return deny_json(deny_reason(name, args if isinstance(args, str) else "", command_path(name)))
    if seen is False and command_path(name):
        _mark_first_skill(base, sid, name)
    return None


def _mark_first_skill(base, sid, name):
    """첫 호출의 표시를 세운다. 이미 유효한 표시가 있으면(오피스 거부 등) 횟수를 지키고, 이름이 같을 때만
    파일 이름도 지킨다. 횟수 줄이 못 쓴 표시는 손대지 않는다(Stop 이 지운다). 잠금을 못 얻으면 넘어간다."""
    marker = pending_path(base, sid)
    with session_lock(base, sid) as got:
        if not got:
            return
        prev = read_pending(marker)
        if prev is None:
            set_pending(marker, name)
            return
        if prev[1] is None:
            return
        stem = prev[2] if prev[0] == name else ""
        set_pending(marker, name, prev[1], stem)


def deny_office(obj, kind, how, target):
    """오피스 형식 kind 로 만들려는 시도를 거부한다. 세션 기록은 읽기만 하고, 명령이 설치되어 있으면 표시도 남긴다."""
    sid = session_id(obj)
    called = False
    if sid:
        base = state_dir(False)
        if base:
            called = already_called(base, sid, kind)
    cmd = command_path(kind)
    stem = safe_stem(target)
    if cmd and sid:
        mark_office(sid, kind, stem or "")
    return deny_json(office_reason(kind, called, cmd, how, stem))


def mark_office(sid, kind, stem):
    """오피스 쓰기 거부를 표시로 남긴다. 이미 유효한 표시가 있으면 횟수만 유지해 이름을 바꾼다. 횟수 줄이
    못 쓴 표시는 손대지 않고(Stop 이 지운다), 잠금을 못 얻으면 표시를 건너뛴다. 실패는 무시한다."""
    base = state_dir(True)
    if base is None:
        return
    marker = pending_path(base, sid)
    with session_lock(base, sid) as got:
        if not got:
            return
        prev = read_pending(marker)
        if prev and prev[1] is None:
            return
        set_pending(marker, kind, prev[1] if prev else 0, stem)


def handle_office_write(obj, tool_input):
    """Write/Edit/MultiEdit 이 오피스 확장자 file_path 로 쓰려 하면 거부한다(그 경로 이름도 함께 넘긴다)."""
    path = tool_input.get("file_path")
    if not isinstance(path, str):
        return None
    kind = office_type(path)
    return deny_office(obj, kind, "Write/Edit", path) if kind else None


def clear_run_skill(obj, tokens):
    """표시된 skill 명령을 인자와 함께 돌리는 토큰이면 표시를 지운다. 표시가 없으면 아무 기록도 만들지
    않고, 잠금을 못 얻으면 지우지 않는다(다음 Stop 이 다시 판단한다)."""
    sid = session_id(obj)
    if sid is None:
        return None
    base = state_dir(False)
    if base is None:
        return None
    marker = pending_path(base, sid)
    with session_lock(base, sid) as got:
        if got:
            prev = read_pending(marker)
            if prev and runs_skill_script(tokens, prev[0]):
                clear_pending(marker)
    return None


def handle_bash(obj, tool_input):
    """Bash: 오피스 만들기 거부 → 끝나지 않은 heredoc 거부 → from-md 결과 이름 검사 → 확실할 때만 skill
    명령 실행 표시를 지운다."""
    command = tool_input.get("command")
    if not isinstance(command, str):
        return None
    tokens, sure, unclosed = shell_words(command)
    hit = redirect_office(tokens)
    if hit:
        return deny_office(obj, hit[0], "Bash 리다이렉트(> >> tee)", hit[1])
    hit = bash_office_type(tokens)
    if hit:
        return deny_office(obj, hit[0], hit[1], hit[2])
    if unclosed:  # 이 거부는 표시를 만들거나 지우지 않는다(명령이 아예 돌지 않으므로)
        return deny_json(heredoc_reason(unclosed[0]))
    if sure:  # 이름 검사는 표시(.pending)를 만들지도 지우지도 않는다
        out = from_md_name_block(obj, tokens)
        if out:
            return out
        clear_run_skill(obj, tokens)
    return None


def handle_stop(obj):
    """Stop: 표시(.pending) 로직이 먼저다(안내만 읽고 명령을 안 돌렸으면 최대 두 번 막는다). 표시 쪽이 허용할
    때만 끝 답의 '만들었다' 주장을 검사한다. 판단 전체를 잠금으로 묶어 동시 판정이 횟수를 되돌리지 않게 하고,
    잠금을 못 얻으면 허용한다(표시도 손대지 않는다)."""
    sid = session_id(obj)
    if sid is None:
        return None
    base = state_dir(False)
    if base is None:
        return None
    marker = pending_path(base, sid)
    with session_lock(base, sid) as got:
        if not got:
            return None
        out = marker_stop_block(obj, base, sid, marker)
        return out if out is not None else claim_stop_block(obj, base, sid)


def marker_stop_block(obj, base, sid, marker):
    """표시(.pending) 로 막는 쪽: 횟수를 늘려 적고 최대 두 번 막는다. 두 번을 넘으면(횟수 줄을 못 읽거나
    2 이상이면) 표시를 지우고 허용한다. 파일 이름 줄이 비어 있으면 대화 기록의 마지막 사용자 요청에서 찾는다."""
    prev = read_pending(marker)
    if prev is None:
        return None
    name, count, stem = prev
    cmd = command_path(name)
    if cmd is None:
        return None
    if count is None or count >= 2:
        clear_pending(marker)
        return None
    if not set_pending(marker, name, count + 1, stem):
        return None  # 표시를 못 쓰면(읽기 전용 상태 폴더 등) 막지 않는다(거듭 막지 않게)
    if not stem:
        stem = transcript_stem(obj, name)
    called = already_called(base, sid, name)
    return json.dumps({"decision": "block", "reason": stop_reason(name, cmd, count, stem, called)},
                      ensure_ascii=False)


def claim_stop_block(obj, base, sid):
    """끝 답 주장 검사: '만들었다'고 한 오피스 파일이 없으면 세션당 한 번(<세션>.claim) 막는다. 이미 한 번
    막은 세션이면 주장 파일을 하나도 열어 보지 않고 허용한다. 끝 답이나 cwd 가 확실하지 않거나, 그 종류
    명령이 설치되지 않았거나, 표시를 못 쓰면 허용한다."""
    claim = os.path.join(base, sid + ".claim")
    try:
        os.lstat(claim)
        return None  # 이미 한 번 막은 세션이다
    except OSError:
        pass
    message = obj.get("last_assistant_message")
    cwd = obj.get("cwd")
    if not isinstance(message, str) or not message:
        return None
    if not isinstance(cwd, str) or not os.path.isdir(cwd):
        return None
    missing = [(name, kind) for name, kind in missing_claimed_files(message, cwd) if command_path(kind)]
    if not missing:
        return None
    try:
        fd = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError:
        return None  # 다른 프로세스가 방금 만들었거나 못 쓰면 허용
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as h:
            h.write(" ".join(name for name, _kind in missing))
    except OSError:
        return None
    return json.dumps({"decision": "block", "reason": claim_reason(missing)}, ensure_ascii=False)


def handle_tool(obj):
    """PreToolUse 를 도구별로 나눈다(Skill · Write/Edit/MultiEdit · Bash). 나머지 도구는 손대지 않는다."""
    tool_input = obj.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    tool = obj.get("tool_name")
    if tool in ("Write", "Edit", "MultiEdit"):
        return handle_office_write(obj, tool_input)
    if tool == "Bash":
        return handle_bash(obj, tool_input)
    if tool == "Skill":
        return handle_skill(obj, tool_input)
    return None


def decide(raw):
    """허용이면 None(출력 없음), 막으면 그 출력 한 줄(PreToolUse 거부 JSON / Stop 차단 JSON)."""
    obj = parse_event(raw)
    if obj is None:
        return None
    event = obj.get("hook_event_name")
    if event == "Stop":
        return handle_stop(obj)
    if event in (None, "PreToolUse"):
        return handle_tool(obj)
    return None


def main():
    try:
        raw = sys.stdin.buffer.read().decode("utf-8", "replace")
        out = decide(raw)
        if out:
            sys.stdout.buffer.write(out.encode("utf-8") + b"\n")
    except Exception:
        pass


if __name__ == "__main__":
    main()
