\\ Every allocation collects. Exercise retained strings, object dictionaries and builder growth.
(let Value (json.parse "{c#34;textc#34;:c#34;éλ😀c#92;u0000c#34;,c#34;numbersc#34;:[-0,1e999,42]}" [])
     B (buffer.builder 2048)
     _ (buffer.append! B (buffer.new 700))
     _ (buffer.append! B (json.encode Value []))
     Wire (buffer.finish B)
     Parsed (json.decode (buffer.slice Wire 700 (- (buffer.length Wire) 700)) [])
     _ (shen-jit.collect)
  (if (= Value Parsed) (output "json gc ok~%") (error "JSON ownership failed under GC stress")))
