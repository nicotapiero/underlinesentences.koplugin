# underlinesentences.koplugin

TODO:
[ ] When you highlight something, the sentence highlights go on top of it, making a weird pattern of dark/light highlights instead of contiguous dark
[ ] Probably update _meta.lua
[ ] Probably delete all the testing stuff / version numbers / etc 


box version:
alternating with 

```
for index, sentence in ipairs(sentences) do

    -- Draw only alternating sentences.
    if index % 2 == 1
        and sentence.boxes
        and #sentence.boxes > 0 then

        plugin:drawSentenceOutline(
            bb,
            sentence.boxes
        )
    end
end
```

does generally look better, but still want
[] non-boxed sections to have their horizontal lines
[] perhaps we always start every section on the first letter of the sentence, as right now by alternating you get lines after periods / lines at the start of a word alternating
