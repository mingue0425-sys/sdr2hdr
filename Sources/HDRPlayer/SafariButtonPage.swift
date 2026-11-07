import Foundation

/// A local page that explains and offers the Safari bookmarklet, which sends
/// the current tab's address to HDRPlayer through `hdrplayer://open?url=`.
enum SafariButtonPage {
    static var html: String {
        let link = YouTubeLink.bookmarklet
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!DOCTYPE html>
        <html lang="ko">
        <head>
        <meta charset="utf-8">
        <title>Safari에 HDR 버튼 추가</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; max-width: 640px; margin: 48px auto; padding: 0 24px; }
          h1 { font-size: 22px; margin-bottom: 8px; }
          .button { display: inline-block; margin: 20px 0; padding: 10px 18px; border-radius: 10px;
                    background: #d9342b; color: white; font-weight: 600; text-decoration: none; cursor: grab; }
          ol { padding-left: 20px; }
          li { margin: 8px 0; }
          .note { color: #777; font-size: 13px; }
          kbd { font: 12px ui-monospace, monospace; padding: 1px 5px; border: 1px solid #aaa; border-radius: 4px; }
        </style>
        </head>
        <body>
        <h1>Safari에 “HDR로 보기” 버튼 추가</h1>
        <p>이 버튼을 즐겨찾기 막대에 넣어 두면, 유튜브 영상을 보다가 한 번 눌러 HDRPlayer로 넘길 수 있습니다.</p>
        <a class="button" href="\(link)">HDR로 보기</a>
        <ol>
          <li>즐겨찾기 막대를 켭니다: 보기 → 즐겨찾기 막대 보기 (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>B</kbd>).</li>
          <li>위의 빨간 <b>HDR로 보기</b> 버튼을 즐겨찾기 막대로 끌어다 놓습니다.</li>
          <li>유튜브 영상 페이지에서 그 버튼을 누릅니다. 처음 한 번 “HDRPlayer를 여시겠습니까?”라고 물으면 <b>허용</b>을 누르세요.</li>
          <li>HDRPlayer가 영상을 H.264(최대 1080p)로 한 번 받아 두고 HDR로 재생합니다. 같은 영상은 다시 받지 않습니다.</li>
        </ol>
        <p class="note">HDRPlayer 메뉴의 파일 → “Safari 현재 탭의 유튜브 열기”(<kbd>⌘</kbd><kbd>⇧</kbd><kbd>L</kbd>)로도 같은 일을 할 수 있습니다.
        브라우저 쿠키나 로그인 정보는 쓰지 않습니다.</p>
        </body>
        </html>
        """
    }
}
