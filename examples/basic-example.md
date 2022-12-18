---
title: A basic paper with pandoc and pandoc-glossify
abstract: >
  This markdown document shows how to setup a simple
  paper using pandoc and pandoc-glossify. It illustrates
  the use of interlinear glosses, citations as well as 
  some other pandoc features. 

# bibliography information
bibliography: bibliography.bib
citation-style: unified-style-sheet-for-linguistics.csl

# these are the parameters for the LaTeX (PDF) engine
pdf-engine: xelatex 
geometry: a4paper,margin=2cm
mainfont: Libertinus Serif
sansfont: Libertinus Sans
monofont: Libertinus Mono
fontsize: 10pt

---

# Introduction

This is a sample markdown document that illustrates how to use some 
basic features of `pandoc` and `pandoc-markdown`, such as:

- basic markdown formatting 
- interlinear glosses
- bibliographic referrences

To convert this document to a PDF or Word file, make sure that you have
the following installed:

1. `Pandoc` (version 2.19 or later)^[on a mac install it via homebrew using the 
   command `brew install pandoc` or consult the [official documentation](https://pandoc.org/installing.html)]

2. An up-to-date `LaTeX` installation (only for PDF)

3. The [*Libertinus* font family](https://github.com/alerque/libertinus/releases) 
   (only for PDF)

Then, execute the following command in your terminal (from the directory where this 
file is located):

\footnotesize
```sh
pandoc -s basic-example.md --lua-filter ../pandoc-glossify.lua --citeproc -o basic-example.docx

pandoc -s basic-example.md --pdf-engine=xelatex --lua-filter ../pandoc-glossify.lua --citeproc -o basic-example.tex

pandoc -s basic-example.md --pdf-engine=xelatex --lua-filter ../pandoc-glossify.lua --citeproc -o basic-example.pdf
```
\normalsize

The above commands `\footnotesize` etc. are `LaTeX` commands to make the text in the 
block smaller. Pandoc can seamlessly detect and integrate such commands, allowing you to 
combine the power of LaTeX with the convenience of Markdown. Note that this will be ingored
by the Word output. 

# Some examples

Example @gloss:next shows that glossed examples are very easy to write with `pandoc-glossify`.
You simply write the lines as you would intuitively, and the software figures out the rest. 
Note also that you can use markdown features (such as citing `@Roberts1998`) in the example 
preamble. 

```gloss
Amele [Trans-New Guinea: Madang, Papua New Guinea, @Roberts1998]
ho   busale-ʔe-b   data age gbo-ig-a     fo?
pig  run.out-DS-3s man  3p  hit-3p-T.PST Q
'Did the pig run out and did the men kill it?'
```

Or another example from @Lehmann1982[pp. 211]:

```gloss
n=an     apedani     mehuni
CONN=him that.DAT.SG time.DAT.SG 
'They shall celebrate him on that date.'
```

You can also have sub-examples like in @gloss:next. 

```{#ex1 .gloss}
This illustrates an example with multiple sub-examples

a. Nepali [@Bickel2010] 
   
   yahã ā-era    khānā     khā-yo?
   here come-CVB food[NOM] eat-3sM.PST

   'Did he come here and eat?' 
   *or* 'Did he eat after coming here?' 
   (presupposing either 'he came' or 'he ate')

b. Indonesian [@Sneddon2012]

   Mereka di Jakarta  sekarang
   they   in  Jakarta now 
   'They are in Jakarta now.'

c. Hittite [@Lehmann1982]
   n=an     apedani     mehuni
   CONN=him that.DAT.SG time.DAT.SG 
   'They shall celebrate him on that date.'
```


# About references

When usign Pandoc with *citeproc* module enabled (via the `--citeproc` option), your
citations will automatically be typeset agains the included bibliography. Pandoc offers a
number of options for displayign citations. You can use a classical citation style using
square brackets [@Lehmann1982] or an author-in-text reference like in @Bickel2010. You can 
also use multiple citations simultaneously using semicolon to separate them [see @Bickel2010;
maybe @Lehmann1982; or @Sneddon2012 on some page, etc.]. The previous example also shows
how you can integrate additional notes into the citation. Pandoc should correctly detect
prefixes and suffices around your citations. If you want to integrate a suffix into an
author-in-text reference you can add square brackets after the citations, e.g. 
@Lehmann1982[pp. 211].

Same exact citation form works with glossed examples. You can use [@gloss:last] or 
@gloss:last to show the last example. Since it also has an explicit label (using the `#ex1`
annotation), you can also use @gloss:ex1. You can also refer to the nested examples as @gloss:last.a
or @gloss:last.b. Finally, you can also refer to a range of examples, for example 
[@gloss:ex1.b; @gloss:last-1; @gloss:ex1.a] — it will be nicely sorted and arranged for you. 


# References

::: {#refs}
:::


