-- #58: seed 공연(c1/c2/c3)의 깨진 한글을 원래 문구로 되돌린다. 깨진 DB에만 한 번 적용한다.
--
-- 원인: 이전 seed.sql 에는 문자셋 선언이 없어, docker-entrypoint-initdb.d 가 UTF-8 파일을 latin1 로 읽어 넣었다.
--       그래서 '올림픽공원' 같은 글자가 'ì˜¬ë¦¼í”½ê³µì›' 형태(이중 인코딩)로 저장됐다. 화면·API 인코딩 문제가 아니다.
-- 범위: 현재 값이 "원래 문구가 깨진 형태"와 정확히 같은 칸만 고친다. 이미 정상이거나 직접 바꾼 값,
--       다른 공연·좌석·예매 데이터는 건드리지 않는다. 다시 실행해도 바뀌는 행이 없다.
USE demo_ticketing_db;
SET NAMES utf8mb4;
START TRANSACTION;
UPDATE concerts c
JOIN (
  SELECT 'c1' AS public_id, 'MIDNIGHT SIGNAL — Seoul Encore' AS title,
    '올림픽공원 KSPO DOME' AS venue, '밤 사이로 번지는 신호, 앙코르 서울' AS tagline
  UNION ALL SELECT 'c2','Paper Lanterns Tour 2026','인스파이어 아레나','종이 등불 아래서 듣는 어쿠스틱 세트'
  UNION ALL SELECT 'c3','Neon Harbor Live','고척스카이돔','항구의 네온, 한 번뿐인 라이브'
) s ON s.public_id = c.public_id
SET
  c.title   = IF(CAST(c.title   AS BINARY) = CAST(CONVERT(CONVERT(CAST(s.title   AS BINARY) USING latin1) USING utf8mb4) AS BINARY), s.title,   c.title),
  c.venue   = IF(CAST(c.venue   AS BINARY) = CAST(CONVERT(CONVERT(CAST(s.venue   AS BINARY) USING latin1) USING utf8mb4) AS BINARY), s.venue,   c.venue),
  c.tagline = IF(CAST(c.tagline AS BINARY) = CAST(CONVERT(CONVERT(CAST(s.tagline AS BINARY) USING latin1) USING utf8mb4) AS BINARY), s.tagline, c.tagline);
SELECT ROW_COUNT() AS repaired_concert_rows;
COMMIT;
SELECT public_id, title, venue, tagline FROM concerts WHERE public_id IN ('c1','c2','c3') ORDER BY public_id;
