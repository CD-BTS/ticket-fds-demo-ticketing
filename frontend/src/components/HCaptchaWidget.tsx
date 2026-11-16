import { useEffect, useRef, useState } from 'react'

interface HCaptchaApi {
  render(container: HTMLElement, params: Record<string, unknown>): string
  remove(widgetId: string): void
}
declare global {
  interface Window {
    hcaptcha?: HCaptchaApi
  }
}

const SCRIPT_SRC = 'https://js.hcaptcha.com/1/api.js?render=explicit&hl=ko'
let loading: Promise<HCaptchaApi> | null = null

/** hCaptcha 스크립트를 한 번만 불러온다 (명시적 render 방식). */
function loadHCaptcha(): Promise<HCaptchaApi> {
  if (window.hcaptcha) return Promise.resolve(window.hcaptcha)
  if (loading) return loading
  loading = new Promise<HCaptchaApi>((resolve, reject) => {
    const script = document.createElement('script')
    script.src = SCRIPT_SRC
    script.async = true
    script.defer = true
    script.onload = () => {
      // 스크립트가 로드된 직후 window.hcaptcha 가 준비될 때까지 잠깐 기다린다
      let tries = 0
      const wait = () => {
        if (window.hcaptcha) resolve(window.hcaptcha)
        else if (++tries > 50) fail()
        else setTimeout(wait, 100)
      }
      wait()
    }
    script.onerror = () => fail()
    const fail = () => {
      loading = null
      script.remove()
      reject(new Error('hCaptcha를 불러오지 못했습니다. 네트워크를 확인한 뒤 다시 시도해 주세요.'))
    }
    document.head.appendChild(script)
  })
  return loading
}

interface Props {
  siteKey: string
  /** 사용자가 확인을 통과하면 hCaptcha 가 만든 토큰을 돌려 준다 */
  onVerify: (token: string) => void
  onError?: (message: string) => void
}

/** hCaptcha 체크박스(필요하면 그림 퍼즐) 위젯. 토큰의 검증은 서버가 한다. */
export default function HCaptchaWidget({ siteKey, onVerify, onError }: Props) {
  const box = useRef<HTMLDivElement>(null)
  const handlers = useRef({ onVerify, onError })
  handlers.current = { onVerify, onError }
  const [loadError, setLoadError] = useState('')

  useEffect(() => {
    let alive = true
    let widgetId: string | undefined
    let api: HCaptchaApi | undefined
    loadHCaptcha()
      .then((hc) => {
        if (!alive || !box.current) return
        api = hc
        widgetId = hc.render(box.current, {
          sitekey: siteKey,
          callback: (token: string) => handlers.current.onVerify(token),
          'error-callback': () => handlers.current.onError?.('보안 확인 중 오류가 발생했습니다. 다시 시도해 주세요.'),
          'expired-callback': () => handlers.current.onError?.('보안 확인이 만료되었습니다. 다시 확인해 주세요.'),
        })
      })
      .catch((e: Error) => {
        if (alive) setLoadError(e.message)
      })
    return () => {
      alive = false
      if (api && widgetId) api.remove(widgetId)
    }
  }, [siteKey])

  return (
    <div>
      {loadError && <p className="error" role="alert">{loadError}</p>}
      <div ref={box} />
    </div>
  )
}
