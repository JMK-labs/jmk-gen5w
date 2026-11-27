# jmk-wifi 드라이버 소스 (GPL-2.0)

jmk-wifi 패키지에 들어 있는 `88x2bu.ko`(Realtek RTL88x2BU USB Wi-Fi 드라이버)와 `8851bu.ko`(RTL8851BU / RTL8831BU, AX900급 동글, 1.4.0부터 시험 지원)를 다시 빌드하는 데 필요한 파일입니다.

| 파일 | 내용 |
|---|---|
| `SOURCE.txt` | 원본 드라이버 주소와 커밋, 패치·커널·툴체인 정보, 빌드된 `88x2bu.ko`의 해시 |
| `patches/` | `88x2bu` 원본 드라이버에 적용한 패치 (이름 순서대로) |
| `SOURCE-8851bu.txt` | `8851bu.ko`의 같은 기록 |
| `patches-8851bu/` | `8851bu` 원본 드라이버에 적용한 패치 (이름 순서대로) |
| `build.sh`, `inner-build.sh` | 빌드 스크립트 |
| `config_tcc803x.txt` | 빌드에 쓴 커널 설정 |
| `COPYING` | GPL-2.0 전문 |

## 원본 드라이버

- `88x2bu.ko`: https://github.com/cilynx/rtl88x2bu (GPL-2.0), 커밋 `fc158d1f71b9e5dfcd1fccaf4d28725b65086e3b`
- `8851bu.ko`: https://github.com/fofajardo/rtl8851bu (GPL-2.0), 커밋 `9e37e7a1101316a05d5daede91549ea779b64539`

## 빌드

Docker가 필요합니다. 이 폴더에서 `./build.sh`를 실행하면 `out/88x2bu.ko`와 `out/SOURCE.txt`가, `DRIVER=8851bu ./build.sh`를 실행하면 `out/8851bu.ko`와 `out/SOURCE-8851bu.txt`가 만들어집니다.

원본 드라이버에 적용한 패치와 빌드 스크립트는 JMK가 직접 만들었습니다.

## 라이선스

원본 드라이버와 패치 모두 GPL-2.0입니다(`COPYING`). 빌드 스크립트(`build.sh`, `inner-build.sh`)와 빌드 방법은 GPL-2.0이 아니라
아래 "사용 조건"을 따릅니다.

## 사용 조건 (빌드 방법에 대해)

`build.sh`와 `inner-build.sh`, 그리고 이 문서가 설명하는 빌드 방법(차 커널을 재현하는 단계의 순서, 어떤 커널·툴체인·옵션을
어떻게 조합하고 어떻게 확인하는지)은 JMK가 jmk-wifi를 위해 직접 만든 것입니다.

- **금지:** JMK의 서면 허락 없이 이 스크립트나 이 방법을 복사·수정하거나, 다른 프로젝트·패키지·배포물·문서에 (고쳐서든 그대로든) 쓰는 것.
- **이 조건이 적용되지 않는 것:** 원본 드라이버 소스, 우리 패치(`patches/`, `patches-8851bu/`), 빌드된 `.ko`는 GPL-2.0입니다(`COPYING`).
  이것들의 사용·수정·재배포 권리는 GPL-2.0이 정하며, 위 금지 조건은 그 권리를 줄이지 않습니다.
- 리눅스 커널과 AOSP 툴체인은 각자의 라이선스를 따릅니다.
