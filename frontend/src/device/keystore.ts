// 티켓별 기기 키 보관소(IndexedDB).
// CryptoKey 객체 자체를 저장하므로(structured clone) 개인키·TOTP 비밀키 원문은 JS 로 꺼낼 수 없다.
// 한계: 같은 브라우저 프로필에서 실행되는 스크립트는 키를 "사용"할 수는 있다. 저장소를 지우면 복구할 수 없고 기기 변경이 필요하다.

const DB_NAME = 'fds.ticket-devices'
const STORE = 'devices'

export interface StoredDevice {
  ticketId: string
  /** 등록한 Demo 사용자. 같은 브라우저에서 다른 사용자로 로그인하면 사용하지 않는다. */
  userId: string
  deviceId: string
  signKey: CryptoKey
  totpKey: CryptoKey
  /** 서버 시각 - 기기 시각(ms). TOTP 계산에 더해 기기 시계 오차를 보정한다. */
  clockOffsetMs: number
}

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === 'undefined') {
      reject(new Error('이 브라우저는 기기 키 저장소(IndexedDB)를 지원하지 않습니다.'))
      return
    }
    const request = indexedDB.open(DB_NAME, 1)
    request.onupgradeneeded = () => request.result.createObjectStore(STORE, { keyPath: 'ticketId' })
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(new Error('기기 키 저장소를 열 수 없습니다. 시크릿 모드에서는 사용할 수 없을 수 있습니다.'))
  })
}

async function run<T>(mode: IDBTransactionMode, work: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open()
  try {
    return await new Promise<T>((resolve, reject) => {
      const tx = db.transaction(STORE, mode)
      const request = work(tx.objectStore(STORE))
      tx.oncomplete = () => resolve(request.result)
      tx.onerror = tx.onabort = () => reject(new Error('기기 키 저장소 작업에 실패했습니다.'))
    })
  } finally {
    db.close()
  }
}

/** 저장소 사용 가능 여부를 서버 호출 전에 확인한다(등록은 됐는데 키를 못 저장하는 상황 방지). */
export async function ensureKeystore(): Promise<void> {
  ;(await open()).close()
}

export async function loadDevice(ticketId: string, userId: string): Promise<StoredDevice | null> {
  const found = (await run<StoredDevice | undefined>('readonly', (store) => store.get(ticketId))) ?? null
  return found && found.userId === userId ? found : null
}

export async function saveDevice(device: StoredDevice): Promise<void> {
  await run('readwrite', (store) => store.put(device))
}
