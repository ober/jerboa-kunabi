#!chezscheme
;;; compile-modules.ss — Compile kunabi library modules

(import (chezscheme))

(parameterize ([optimize-level 2]
               [generate-inspector-information #f]
               [generate-wpo-files #t])
  (for-each compile-library
    '("lib/kunabi/parser.sls"
      "lib/kunabi/config.sls"
      "lib/kunabi/storage.sls"
      "lib/kunabi/loader.sls"
      "lib/kunabi/query.sls"
      "lib/kunabi/detection.sls"
      "lib/kunabi/billing.sls")))

(printf "Compilation complete.~n")
