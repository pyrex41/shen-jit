\\ The libraries are already loaded in the saved image. Every allocation collects.
(let S (http.listen "127.0.0.1" 0
          (/. Q (http.response 200 [] (buffer.from-string "ok"))) [[shutdown-grace 0]])
     C (socket.connect "127.0.0.1" (http.port S))
     _ (socket.send C "GET / HTTP/1.1c#13;c#10;Host: localhostc#13;c#10;c#13;c#10;")
     Reply (socket.recv-string C 4096)
     _ (socket.close C)
     _ (http.stop S)
     Result (http.wait S 5000)
  (if (and (= Result [ok]) (= (http.state S) stopped) (= (hd (http.stats S)) 0))
      (output "listener gc ok~%")
      (error "listener failed under GC stress")))
