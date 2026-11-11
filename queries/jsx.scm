; zile's own, after the grammar's queries (later captures win): JSX
; elements and components (`div`, `View`, `Foo.Bar`) as tags, props as tag
; attributes, and `<` `>` `</` `/>` as tag delimiters, like nvim-treesitter.

(jsx_opening_element name: (_) @tag)
(jsx_closing_element name: (_) @tag)
(jsx_self_closing_element name: (_) @tag)

(jsx_attribute (property_identifier) @tag.attribute)
(jsx_attribute (jsx_namespace_name) @tag.attribute)

(jsx_opening_element ["<" ">"] @tag.delimiter)
(jsx_closing_element ["</" ">"] @tag.delimiter)
(jsx_self_closing_element ["<" "/>"] @tag.delimiter)
