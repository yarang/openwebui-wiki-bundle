# spark-switch

DGX Spark(ARM64, GPU 1장, 통합 메모리 약 121 GB)에서 **한 번에 한 모델만** 서빙하는
vLLM 컨테이너(`vllm-coder`)를 프로필 단위로 교체해 주는 작은 컨트롤러다.
LAN의 신뢰 클라이언트가 "지금 프로필 X를 서빙해 달라"고 요청하면 기존 컨테이너를
교체하고 준비 완료를 기다린 뒤, 일정 시간 idle 하면 기본 프로필로 자동 복귀한다.

## 왜 컨테이너로 실행하나

컨트롤러 자체가 재부팅 후에도 살아 있어야 하는데 DGX Spark는 `systemd linger`
설정 없이는 일반 사용자 프로세스가 남지 않는다. Docker 데몬은 부팅 시 자동으로
올라오므로, `--restart unless-stopped` 컨테이너로 실행하면 별도 설정 없이
재시작된다. Docker API는 호스트 소켓(`/var/run/docker.sock`) 마운트로
`http.client`를 통해 직접 호출한다(컨테이너 안에 docker CLI가 없어도 된다).

## 보안 노트

- **Docker 소켓 마운트 = 사실상 root 권한.** 이 컨트롤러가 임의 명령을 실행하게
  두는 셈이므로 토큰 관리에 신경 쓴다. 코드는 `MANAGED_CONTAINER`
  하나만 다루도록 강제하고, 프로필 이름 외의 입력은 받지 않는다.
- 프로필 이름은 `^[a-z0-9][a-z0-9._-]{0,63}$` 로 검증된 이름만 허용되며,
  `--host`/`--port`/`--served-model-name`/`--api-key` 인자는 profiles.json에
  넣을 수 없다(컨트롤러가 직접 관리하는 플래그).
- 모든 보호 엔드포인트에는 `Authorization: Bearer <SWITCH_TOKEN>`이 필요하다
  (`/health` 제외, 응답은 `{"ok": true}` 뿐). 토큰은 24자 이상.
- **평문 HTTP다.** LAN 이외에 노출하지 말 것. 방화벽/포트 바인딩으로 제한할 것.
- vLLM API 키는 `/config/vllm-env`에서 메모리로만 읽히며 로그·응답·오류에
  절대 출력되지 않는다(실패 로그 tail에 섞여 있으면 `***`로 치환).

## 엔드포인트

| 메서드 | 경로 | 인증 | 설명 |
|---|---|---|---|
| GET | `/health` | 불필요 | `{"ok": true}` |
| GET | `/status` | 필요 | 상태/프로필 목록 |
| POST | `/switch` | 필요 | `{"profile": "<이름>"}` — `default`는 별칭 |

토큰을 셸 히스토리에 남기지 않으려면 호출 시점에 파일에서 읽는다:

```bash
curl -s -H "Authorization: Bearer $(sed -n 's/^SWITCH_TOKEN=//p' ~/spark-switch/env)" \
     http://<spark-host>:8010/status

curl -s -X POST \
     -H "Authorization: Bearer $(sed -n 's/^SWITCH_TOKEN=//p' ~/spark-switch/env)" \
     -H "Content-Type: application/json" \
     -d '{"profile": "gpt-oss-120b"}' \
     http://<spark-host>:8010/switch
```

## profiles.json

`이름 → {model, description, kind: text|vision, verified, args}` 구조.
`args`는 `vllm serve`에 전달될 추가 인자다. **검증(verified)된 프로필은
`qwen3-coder`와 `qwen3-instruct`**이며(실행 중인 컨테이너에서 인자를 그대로 가져옴),
Isaac Sim 병행용 `qwen3-coder-solo`·`gpt-oss-120b-lite`도 2026-11-15 실측으로 검증했다
(SPARK-CLASS-ISAAC-PLAN.md §2). 나머지 세 개는 1차 추정치다 — 처음 전환해 보기 전까지는 동작 보장이 없다.
`qwen3-instruct`의 `--gpu-memory-utilization`은 상주 페어 모드에 맞춰 **0.40**이다
(2026-11-14 측정: 페어 상주 시 instruct KV 약 16만 / coder KV 약 23만 토큰,
MemAvailable 약 14 GiB 남음. 단독 실행 시의 최적값은 0.60 —
[SPARK-BENCH-REPORT.md](../../../docs/dev/SPARK-BENCH-REPORT.md) §8 참고).

| 프로필 | 용도 |
|---|---|
| `qwen3-coder` | 코딩/도구 호출, 30B MoE FP8 (페어 멤버) |
| `qwen3-instruct` (기본) | 일반 대화/수업용, 30B MoE FP8 (페어 멤버, util 0.40) |
| `gpt-oss-120b` | 추론 중심 대형 작업, 120B MoE MXFP4 |
| `qwen3-next-80b` | 긴 문서/일반 작업, 80B (KV 여유 작음) |
| `qwen3-vl-30b` | 이미지 이해 (vision) |

## 동작 규칙

- 전환은 stop → rm → create → start → 준비 대기(`READY_TIMEOUT`, 최대 30분 —
  60–80 GB 모델 첫 로드는 10분 이상 걸린다) 순서다.
- 시작 시 실행 중인 컨테이너는 vLLM이 실제로 그 프로필을 서빙하는지(`/v1/models`
  probe 1회) 확인한 뒤에야 ready로 보고한다. k3s 백엔드에서는 probe보다 먼저
  **입양한 시도의 pod**가 실제로 서빙 중인지도 확인한다 — 같은 프로필 재적용 도중
  컨트롤러가 재시작하면 Service가 아직 옛 pod로 라우팅해 같은 모델 id로 대답하기
  때문에, probe 결과만 믿으면 아직 없거나 로드 중인 교체 pod를 ready로 오인한다.
  컨트롤러 재시작으로 로드 도중을 만나면
  switching/loading으로 입양해 준비 완료만 기다린다(stop/create 없음). 준비 대기 중
  예외(소켓 타임아웃 포함)는 전환 실패로 취급되어 복구 경로를 타며, 상태가
  "switching"에 남는 경우는 없다.
- **idle 자동 복귀**: `IDLE_MINUTES`(기본 30) 동안 요청이 없으면 기본
  프로필로 돌아간다(0이면 비활성). 메트릭 조회 실패는 idle로 간주하지 않는다.
- **쿨다운**: 전환 성공 후 `COOLDOWN_SECONDS`(기본 120) 동안 기본 이외
  프로필 전환은 429 + `retry_after`. 기본 복귀는 막히지 않는다.
- 전환 실패 시 로그 tail을 `last_error`에 남기고, 기본 프로필이 아니면
  기본 프로필로 1회 복구를 시도한다.

## 상주 모드 (pair)

`RESIDENT_PROFILES`에 프로필 2개를 지정하면(기본 설정: `qwen3-instruct,qwen3-coder`)
두 모델이 슬롯에 나뉘어 **동시에 상주**한다. 각 슬롯은 독립된 vLLM 컨테이너다:

| 슬롯 | 컨테이너 | 호스트 포트 | 서빙 |
|---|---|---|---|
| 0 | `vllm-coder` | 8000 | `qwen3-instruct` |
| 1 | `vllm-coder-1` | 8001 | `qwen3-coder` |

- `use qwen3-coder` / `use qwen3-instruct` / `use pair` / `use default`
  모두 **페어 전체**를 불러온다(개별 멤버 이름은 페어의 별칭이다).
  121 GB 통합 메모리에 30B FP8 두 개(util 0.40씩)가 나란히 들어간다.
- 대형 프로필(`gpt-oss-120b` 등)을 요청하면 페어 **둘 다** 내려가고 그 모델
  하나만 올라간다. idle 자동 복귀(`IDLE_MINUTES`)가 지나면 페어가 다시 돌아온다.
- **메모리 대기**: vLLM은 시작 시점의 가용 메모리로 KV 캐시 크기를 정하므로,
  슬롯 생성 전에 `MEM_WAIT_TIMEOUT`초(페어 권장 600)까지 MemAvailable이
  필요량(Σ `--gpu-memory-utilization` × MemTotal + `MEM_MARGIN_GB`)에
  도달할 때까지 기다린다. 두 슬롯은 **순차적으로** 시작한다(슬롯 0이
  `/v1/models`에 응답한 뒤에야 슬롯 1 생성).
- `RESIDENT_PROFILES`를 비우면 단일 컨테이너 모드(기존 동작)로 돌아간다.
  이 기능은 Docker 백엔드 전용이다.

## 설치

Spark에 일반 사용자(docker 그룹)로 실행:

```bash
cd guardian/llm-router/spark
./install-spark-switch.sh --dry-run   # 할 일 확인 (변경 없음)
./install-spark-switch.sh --start     # 설치 + 컨트롤러 컨테이너 시작
```

설치 스크립트는 `~/spark-switch`에 파일을 복사하고, `env`이 없으면
`SWITCH_TOKEN`을 새로 생성해 쓴다(화면에 출력하지 않는다). vLLM API 키 파일
(`~/vllm-work/.vllm-env`, `VLLM_KEY_FILE`으로 재정의 가능)이 미리 있어야 한다.
컨트롤러 컨테이너는 GPU 없이, vLLM 이미지의 python3로 실행된다.

새 `env`는 `VLLM_OFFLINE=1`(오프라인)로 시작한다. vLLM은 모델을 `HF_CACHE_HOST` 캐시에서만
읽고 huggingface.co에 접속하지 않는다. Spark가 인터넷 없는 망에 있을 때 0이면 vLLM이
모델 조회에 실패해 재시작을 반복한다. 새 모델을 내려받을 때만 잠시 0으로 바꾸고
`docker restart spark-switch` 뒤 전환한다. 이미 있는 `env`는 설치기가 바꾸지 않으니
예전 설치는 직접 1로 고친다.

## 롤백

```bash
docker rm -f spark-switch
```

컨트롤러만 사라진다. `vllm-coder` 컨테이너는 그대로 계속 돈다(전환이
요청된 경우에만 교체된다). 다시 쓰고 싶으면 `./install-spark-switch.sh --start`.

## 쿠버네티스(k3s) 설치 (설계 단계 B 이후)

같은 컨트롤러를 단일 노드 k3s 위에서 돌리는 설계와 매니페스트가 준비되어
있다(docs/internal/SPARK-K8S-DESIGN.md 참고).
컨테이너를 직접 만지던 코드는 백엔드 인터페이스 뒤로 분리되었고,
`BACKEND=kubernetes`에서는 Deployment 하나를 패치하는 방식으로 모델을 교체한다.
패치마다 `spark-switch/requested-at` 어노테이션이 새로 발급되고 readiness는
**그 시도의 pod**가 실제로 서빙을 시작한 뒤에만 `/v1/models` probe로 판정한다
(Service는 새 pod가 준비될 때까지 옛 pod로 라우팅하므로, 같은 프로필 재적용
중에는 옛 pod가 기대한 모델 id로 대답해 버린다).

**현재 기본은 계속 Docker 설치다.** k3s 설치는 설계 단계 B(클러스터 준비)가
끝난 뒤 시도한다. 설치 스크립트 `install-spark-k8s.sh` 옵션:

| 옵션 | 동작 |
|---|---|
| (없음) | 사전 점검 + 매니페스트 검증(`kubectl kustomize`와 dry-run apply를 실제 실행, 변경 없음) |
| `--apply` | Secret 생성(있으면 유지) 후 매니페스트 적용, `/health` 대기 |
| `--import-image` | `docker save` \| `sudo k3s ctr images import` |
| `--device-plugin` | RuntimeClass `nvidia` + NVIDIA device plugin 적용 |
| `--migrate-from-docker` | `docker stop spark-switch vllm-coder`(제거 아님) 후 `--apply` |
| `--rollback-to-docker` | `spark-llm`을 0으로 축소, Service 삭제, **pod가 실제로 종료될 때까지 대기** 후 `docker start` |
| `--rotate-token` | `SWITCH_TOKEN` 재발급(Mac 쪽 `SPARK_SWITCH_TOKEN`도 갱신 필요; `--dry-run`과 함께 쓰면 토큰을 바꾸지 않고 할 일만 출력) |
| `--with-policy` | 선택 3겹 방어(ValidatingAdmissionPolicy) 적용 — 컨테이너 args와 `spark-switch/profile`·`spark-switch/requested-at` 어노테이션 외에는 템플릿 전체를 변경 불가로 고정 |

설치 스크립트 세부 동작:

- **사전 점검은 동작별로 다르다.** `--rollback-to-docker`·`--import-image`는
  GPU/RuntimeClass/HF 캐시 상태와 무관하게 진행한다(비상 경로가 고장난
  플러그인에 막히면 안 된다). dry-run/apply/migrate만 전부 검사하며, migrate는
  docker 바이너리도 사전에 확인한다(컨테이너를 멈춰야 하므로). Secret
  **값**도 검사한다(`VLLM_API_KEY` 비어 있으면 안 됨, `SWITCH_TOKEN` 24자
  이상 — 값 자체는 절대 출력/argv에 놓이지 않는다) — `--migrate-from-docker`가
  Docker 컨테이너를 멈추기도 전에 실패한다.
- **포트 점검은 Service 단위다.** 이미 존재하는 Service의 포트(예: 재적용
  중인 `vllm-coder`의 8000)가 열려 있는 것은 정상으로 본다; 없는 Service의
  포트만 비어 있어야 한다.
- **rollback은 pod가 실제로 사라질 때까지 기다린 뒤** Docker를 시작한다.
  축소/Service 삭제가 실패하면 경고하고 계속하지만, 300초 후에도 pod가 남으면
  GPU를 붙잡고 있을 수 있어 Docker를 시작하지 않고 실패로 끝난다. "사라졌다"의
  판정은 **조회에 성공한 빈 pod 목록**뿐이다 — pod 목록 조회 자체가 실패하면
  pod가 없다는 뜻이 아니므로 거부한다.
- **`VLLM_IMAGE` 재정의는 `newName`과 `newTag`를 모두 다시 쓴다.** 레지스트리
  주소가 바뀌어도 기본 nvcr.io 이미지가 조용히 배포되는 일이 없다(`name:tag`
  형식만 허용, 다이제스트 참조는 거부).
- **`OFFLINE=1`이면 스테이징된 overlay에만 오프라인 패치가 붙는다.**
  `overlays/spark/offline-env-patch.yaml`(`HF_HUB_OFFLINE=1`,
  `TRANSFORMERS_OFFLINE=1`, `TIKTOKEN_ENCODINGS_BASE=...`)을 vllm-coder
  Deployment의 env에 병합한다. 저장소의 overlay 파일은 그대로(온라인 설치와
  바이트 동일)이고, `OFFLINE`을 아예 설정하지 않거나 `0`이면 결과물에 패치가
  없다.

## 오프라인(에어갭) 설치

DGX가 인터넷 없이 설치되도록 두 단계로 나뉜다. **패킹은 연결된 arm64 리눅스
호스트에서**(보통 인터넷이 아직 되는 DGX 자신), **설치는 에어갭 DGX에서** 번들
디렉터리만 읽고 진행한다(네트워크 호출 0회 — 스크립트 소스에 curl/wget조차
없고 테스트가 이를 강제한다). Mac 쪽 guardian 번들은 건드리지 않는다.

### 1단계 — 번들 만들기 (연결된 호스트)

```bash
./pack-spark-offline.sh --out /mnt/usb/spark-bundle            # 모든 프로필
./pack-spark-offline.sh --out DIR --profiles gpt-oss-120b,qwen3-coder
./pack-spark-offline.sh --out DIR --dry-run                    # 명령만 출력
```

번들 구성: `k3s/`(바이너리 + 에어갭 이미지 tarball + install.sh, sha256
대조 검증), `images/`(vLLM·device plugin `docker save` tar, arm64 강제,
`IMAGE_IDS`에 tar→ref→id 기록), `hf/hub/`(모델 캐시 — snapshot symlink를
**symlink 그대로** 보존), `hf/tiktoken/`(gpt-oss 프로필이 있을 때만),
`spark/`(설치 스크립트+매니페스트, 비밀 제외), `MANIFEST.json`,
`SHA256SUMS`(일반 파일 전수 — 단 `.done-*` 마커와 `.partial` 경로 제외).
컴포넌트는 `.partial` 스테이징 후 rename되므로 실패하면 `--resume`으로
이어서 패킹한다. 모델은 **프로필 단위로** 재개된다(`.done-model-<profile>`
마커, 다운로드는 이어받기) — 한 모델이 실패해도 나머지를 다시 받지 않고,
모델을 다시 패킹해도 `hf/tiktoken`은 지워지지 않는다. 모델별 중복 가중치
트리(`original/`, `metal/`)는 기본적으로 제외되고(`--include-all-files`로
해제, MANIFEST의 `exclude`에 기록) — 용량이 약 절반으로 줄어든다. 로컬 HF
캐시에서 복사할 때는 `refs/main`이 가리키는 snapshot의 symlink와 **참조된
blob만** 복사한다(dangling/이탈 symlink면 그 항목은 버리고 다운로드로
대체). `.partial`이 하나라도 남으면 MANIFEST/SHA256SUMS 생성을 거부한다.
마지막 비밀 가드가 `SWITCH_TOKEN=`/`VLLM_API_KEY=`/`HF_TOKEN=` 실값이나
`env`·`*.key`·`token*` 파일이 번들에 섞이면 거부한다. `HF_TOKEN`은 게이트된
저장소 다운로드를 위해 환경에서 상속만 되고(docker fallback은
`--user`로 실행, `-e HF_TOKEN` **이름만** 전달) 절대 기록되지 않는다.

### 2단계 — 설치 (에어갭 DGX)

```bash
./install-spark-offline.sh --bundle /mnt/usb/spark-bundle          # = --verify
./install-spark-offline.sh --bundle DIR --all                     # 전체 순서 실행
```

`--all`은 **verify → --install-k3s → --load-images → --load-models** 순서.
모든 동작 앞에 읽기 전용 verify(MANIFEST 형식/아키텍처, SHA256SUMS 전수 대조,
참조 파일 존재, **HF snapshot symlink 안전 검사** — 절대경로/이탈/dangling
링크나 snapshots/ 안의 일반 파일이 있으면 거부)가 항상 먼저 돈다. NVIDIA
container toolkit은 DGX OS가 이미 제공해야 한다(번들에 없음 — 없으면 설치 전에
실패). `--install-k3s`는 sudo 복사 **전에** 디스크 여유(필요량 + 10%)를
검사하고, install.sh 후 `/etc/rancher/k3s/k3s.yaml`이 생길 때까지 최대 60초
(`K3S_KUBECONFIG_WAIT_SECONDS`로 조정) 기다린 뒤 사용자 소유 0600 kubeconfig
로 복사한다(중간에 절대 group/world 읽기 권한이 생기지 않는다). 이미 다른
버전의 k3s가 있으면 덮어쓰지 않고 거부한다. 모델 병합은 기존 blob이 같으면
건너뛰고 다르면 절대 덮어쓰지 않으며, 필요 공간은 **아직 없는 파일만** 센다.
tiktoken도 파일 단위로 같은 규칙(동일 skip, 상이 거부, symlink 거부)을
따른다. `ctr` 이미지 확인은 라인 단위 정확 매치다. `--dry-run`은 verify만
실행하고 나머지는 출력만.

### 3단계 — k3s 배포 (OFFLINE=1)

번들 안의 spark 사본에서:

```bash
cd /mnt/usb/spark-bundle/spark
OFFLINE=1 ./install-spark-k8s.sh --dry-run
OFFLINE=1 ./install-spark-k8s.sh --device-plugin
OFFLINE=1 ./install-spark-k8s.sh --apply      # 또는 --migrate-from-docker
```

Docker 컨트롤러 쪽(`env.example`의 `VLLM_OFFLINE=1`)도 같은 세 환경변수를
vLLM 컨테이너에 주입한다 — Docker와 k3s 양쪽에서 HF 허브 접속 시도를 끈다.

## 테스트

```bash
python3 -m unittest discover -s guardian/llm-router/spark/tests -v
```
