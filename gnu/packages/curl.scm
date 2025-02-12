;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2013, 2014, 2015 Andreas Enge <andreas@enge.fr>
;;; Copyright © 2015 Mark H Weaver <mhw@netris.org>
;;; Copyright © 2015 Tomáš Čech <sleep_walker@suse.cz>
;;; Copyright © 2015, 2020, 2021, 2022 Ludovic Courtès <ludo@gnu.org>
;;; Copyright © 2016, 2017, 2019 Leo Famulari <leo@famulari.name>
;;; Copyright © 2017, 2019, 2020, 2022 Marius Bakke <marius@gnu.org>
;;; Copyright © 2017, 2023 Efraim Flashner <efraim@flashner.co.il>
;;; Copyright © 2017, 2018 Tobias Geerinckx-Rice <me@tobias.gr>
;;; Copyright © 2018 Roel Janssen <roel@gnu.org>
;;; Copyright © 2019, 2021 Ricardo Wurmus <rekado@elephly.net>
;;; Copyright © 2020 Jakub Kądziołka <kuba@kadziolka.net>
;;; Copyright © 2020 Dale Mellor <guix-devel-0brg6b@rdmp.org>
;;; Copyright © 2020 Jan (janneke) Nieuwenhuizen <janneke@gnu.org>
;;; Copyright © 2021 Jean-Baptiste Volatier <jbv@pm.me>
;;; Copyright © 2021 Felix Gruber <felgru@posteo.net>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu packages curl)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix utils)
  #:use-module (guix build-system cmake)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system go)
  #:use-module (guix build-system meson)
  #:use-module ((guix search-paths) #:select ($SSL_CERT_DIR $SSL_CERT_FILE))
  #:use-module (gnu packages)
  #:use-module (gnu packages check)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages golang)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages kerberos)
  #:use-module (gnu packages logging)
  #:use-module (gnu packages libevent)
  #:use-module (gnu packages libidn)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages tls)
  #:use-module (gnu packages web)
  #:use-module (srfi srfi-1))

(define-public curl
  (package
   (name "curl")
   (version "7.79.1")
   (replacement curl-7.84.0)
   (source (origin
             (method url-fetch)
             (uri (string-append "https://curl.se/download/curl-"
                                 version ".tar.xz"))
             (sha256
              (base32
               "129n9hi7rbg3s112chyadhp4y27ppb5i65n12wm77aw2255zf1h6"))
             (patches (search-patches "curl-use-ssl-cert-env.patch"))))
   (build-system gnu-build-system)
   (outputs '("out"
              "doc"))                             ;1.2 MiB of man3 pages
   (inputs (list gnutls libidn mit-krb5
                 `(,nghttp2 "lib") zlib))
   (native-inputs
     `(("nghttp2" ,nghttp2)
       ("perl" ,perl)
       ("pkg-config" ,pkg-config)
       ("python" ,python-minimal-wrapper)))
   (native-search-paths
    ;; These variables are introduced by curl-use-ssl-cert-env.patch.
    (list $SSL_CERT_DIR
          $SSL_CERT_FILE
          ;; Note: This search path is respected by the `curl` command-line
          ;; tool only.  Patching libcurl to read it too would bring no
          ;; advantages and require maintaining a more complex patch.
          (search-path-specification
           (variable "CURL_CA_BUNDLE")
           (file-type 'regular)
           (separator #f)                         ;single entry
           (files '("etc/ssl/certs/ca-certificates.crt")))))
   (arguments
    `(#:disallowed-references ("doc")
      #:configure-flags (list "--with-gnutls"
                              (string-append "--with-gssapi="
                                             (assoc-ref %build-inputs "mit-krb5"))
                              "--disable-static")
      #:phases
      (modify-phases %standard-phases
        (add-after 'unpack 'do-not-record-configure-flags
          (lambda _
            ;; Do not save the configure options to avoid unnecessary references.
            (substitute* "curl-config.in"
              (("@CONFIGURE_OPTIONS@")
               "\"not available\""))))
        (add-after
         'install 'move-man3-pages
         (lambda* (#:key outputs #:allow-other-keys)
           ;; Move section 3 man pages to "doc".
           (let ((out (assoc-ref outputs "out"))
                 (doc (assoc-ref outputs "doc")))
             (mkdir-p (string-append doc "/share/man"))
             (rename-file (string-append out "/share/man/man3")
                          (string-append doc "/share/man/man3")))))
        (replace 'check
          (lambda* (#:key tests? #:allow-other-keys)
            (substitute* "tests/runtests.pl"
              (("/bin/sh") (which "sh")))

            (when tests?
              ;; The top-level "make check" does "make -C tests quiet-test", which
              ;; is too quiet.  Use the "test" target instead, which is more
              ;; verbose.
              (invoke "make" "-C" "tests" "test")))))))
   (synopsis "Command line tool for transferring data with URL syntax")
   (description
    "curl is a command line tool for transferring data with URL syntax,
supporting DICT, FILE, FTP, FTPS, Gopher, HTTP, HTTPS, IMAP, IMAPS, LDAP,
LDAPS, POP3, POP3S, RTMP, RTSP, SCP, SFTP, SMTP, SMTPS, Telnet and TFTP.
curl supports SSL certificates, HTTP POST, HTTP PUT, FTP uploading, HTTP
form based upload, proxies, cookies, file transfer resume, user+password
authentication (Basic, Digest, NTLM, Negotiate, kerberos...), proxy
tunneling, and so on.")
   (license (license:non-copyleft "file://COPYING"
                                  "See COPYING in the distribution."))
   (home-page "https://curl.haxx.se/")))

;; Replacement package with fixes for multiple vulnerabilities.
;; See <https://curl.se/docs/security.html>.
(define curl-7.84.0
  (package
    (inherit curl)
    (version "7.84.0")
    (source (origin
              (inherit (package-source curl))
              (uri (string-append "https://curl.se/download/curl-"
                                  version ".tar.xz"))
              (sha256
               (base32
                "1f2xgj0wvys9xw50h7vcbaraavjr9rxx9n06x2xfbgs7ym1qn49d"))
              (patches (append (origin-patches (package-source curl))
                               (search-patches "curl-easy-lock.patch")))))
    (arguments (substitute-keyword-arguments (package-arguments curl)
                 ((#:phases phases)
                  (cond
                   ((not (target-64bit?))
                    #~(modify-phases #$phases
                        (add-after 'unpack 'tweak-lib3026-test
                          (lambda _
                            ;; Have that test create a hundred threads, not a
                            ;; thousand.
                            (substitute* "tests/libtest/lib3026.c"
                              (("NUM_THREADS .*$")
                               "NUM_THREADS 100\n"))))))
                   (else phases)))))))

(define-public curl-minimal
  (deprecated-package "curl-minimal" curl))

(define-public curl-ssh
  (package/inherit curl
    (arguments
     (substitute-keyword-arguments (package-arguments curl)
       ((#:configure-flags flags)
        `(cons "--with-libssh2" ,flags))))
    (inputs
     `(("libssh2" ,libssh2)
       ,@(package-inputs curl)))
    (properties `((hidden? . #t)))))

(define-public kurly
  (package
    (name "kurly")
    (version "1.2.2")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                     (url "https://gitlab.com/davidjpeacock/kurly.git")
                     (commit (string-append "v" version))))
              (file-name (git-file-name name version))
              (sha256
               (base32
                "003jv2k45hg2svhjpy5253ccd250vi2r17x2zhm51iw54kgwxipm"))))
    (build-system go-build-system)
    (arguments
     `(#:import-path "gitlab.com/davidjpeacock/kurly"
       #:install-source? #f
       #:phases
       (modify-phases %standard-phases
         (add-after 'install 'install-documentation
           (lambda* (#:key import-path outputs #:allow-other-keys)
             (let* ((source (string-append "src/" import-path))
                    (out (assoc-ref outputs "out"))
                    (doc (string-append out "/share/doc/" ,name "-" ,version))
                    (man (string-append out "/share/man/man1")))
               (with-directory-excursion source
                 (install-file "README.md" doc)
                 (mkdir-p man)
                 (copy-file "doc/kurly.man"
                            (string-append man "/kurly.1")))
               #t))))))
    (inputs
     (list go-github-com-alsm-ioprogress go-github-com-aki237-nscjar
           go-github-com-urfave-cli))
    (synopsis "Command-line HTTP client")
    (description "kurly is an alternative to the @code{curl} program written in
Go.  kurly is designed to operate in a similar manner to curl, with select
features.  Notably, kurly is not aiming for feature parity, but common flags and
mechanisms particularly within the HTTP(S) realm are to be expected.  kurly does
not offer a replacement for libcurl.")
    (home-page "https://gitlab.com/davidjpeacock/kurly")
    (license license:asl2.0)))

(define-public guile-curl
  (package
   (name "guile-curl")
   (version "0.9")
   (source (origin
            (method url-fetch)
            (uri (string-append "http://www.lonelycactus.com/tarball/"
                                "guile_curl-" version ".tar.gz"))
            (sha256
             (base32
              "0y7wfhilfm6vzs0wyifrrc2pj9nsxfas905c7qa5cw4i6s74ypmi"))))
   (build-system gnu-build-system)
   (arguments
    `(#:modules (((guix build guile-build-system)
                  #:select (target-guile-effective-version))
                 ,@%gnu-build-system-modules)
      #:imported-modules ((guix build guile-build-system)
                          ,@%gnu-build-system-modules)
      #:configure-flags (list (string-append
                               "--with-guilesitedir="
                               (assoc-ref %outputs "out")
                               "/share/guile/site/"
                               (target-guile-effective-version
                                (assoc-ref %build-inputs "guile")))
                              (string-append
                               "-with-guileextensiondir="
                               (assoc-ref %outputs "out")
                               "/lib/guile/"
                               (target-guile-effective-version
                                (assoc-ref %build-inputs "guile"))
                               "/extensions"))
      #:phases
      (modify-phases %standard-phases
        (add-after 'unpack 'patch-undefined-references
          (lambda* _
            (substitute* "module/curl.scm"
              ;; The following #defines are missing from our curl package
              ;; and therefore result in the evaluation of undefined symbols.
              ((",CURLOPT_HAPROXYPROTOCOL") "#f")
              ((",CURLOPT_DISALLOW_USERNAME_IN_URL") "#f")
              ((",CURLOPT_TIMEVALUE_LARGE") "#f")
              ((",CURLOPT_DNS_SHUFFLE_ADDRESSES") "#f")
              ((",CURLOPT_HAPPY_EYEBALLS_TIMEOUT_MS") "#f"))))
        (add-after 'install 'patch-extension-path
          (lambda* (#:key outputs #:allow-other-keys)
            (let* ((out      (assoc-ref outputs "out"))
                   (curl.scm (string-append
                              out "/share/guile/site/"
                              (target-guile-effective-version)
                              "/curl.scm"))
                   (curl.go  (string-append
                              out "/lib/guile/"
                              (target-guile-effective-version)
                              "/site-ccache/curl.go"))
                   (ext      (string-append out "/lib/guile/"
                                            (target-guile-effective-version)
                                            "/extensions/libguile-curl")))
              (substitute* curl.scm (("libguile-curl") ext))
              ;; The build system does not actually compile the Scheme module.
              ;; So we can compile it and put it in the right place in one go.
              (invoke "guild" "compile" curl.scm "-o" curl.go)))))))
   (native-inputs (list pkg-config))
   (inputs
    (list curl guile-3.0))
   (home-page "http://www.lonelycactus.com/guile-curl.html")
   (synopsis "Curl bindings for Guile")
   (description "@code{guile-curl} is a project that has procedures that allow
Guile to do client-side URL transfers, like requesting documents from HTTP or
FTP servers.  It is based on the curl library.")
   (license license:gpl3+)))

(define-public guile2.2-curl
  (package
    (inherit guile-curl)
    (name "guile2.2-curl")
    (inputs
     (list curl guile-2.2))))

(define-public curlpp
  (package
    (name "curlpp")
    (version "0.8.1")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/jpbarrette/curlpp")
             (commit (string-append "v" version))))
       (sha256
        (base32 "1b0ylnnrhdax4kwjq64r1fk0i24n5ss6zfzf4hxwgslny01xiwrk"))
       (file-name (git-file-name name version))))
    (build-system cmake-build-system)
    ;; There are no build tests to be had.
    (arguments
     '(#:tests? #f))
    ;; The installed version needs the header files from the C library.
    (propagated-inputs
     (list curl))
    (synopsis "C++ wrapper around libcURL")
    (description
     "This package provides a free and easy-to-use client-side C++ URL
transfer library, supporting FTP, FTPS, HTTP, HTTPS, GOPHER, TELNET, DICT,
FILE and LDAP; in particular it supports HTTPS certificates, HTTP POST, HTTP
PUT, FTP uploading, kerberos, HTTP form based upload, proxies, cookies,
user+password authentication, file transfer resume, http proxy tunneling and
more!")
    (home-page "http://www.curlpp.org")
    (license license:expat)))

(define-public h2c
  (package
    (name "h2c")
    (version "1.0")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/curl/h2c")
             (commit version)))
       (sha256
        (base32
         "1n8z6avzhg3yb330di2y9zymsps1qp1235p29kidcp4fkmn7fgb2"))
       (file-name (git-file-name name version))))
    (build-system copy-build-system)
    (arguments
     '(#:install-plan
       '(("./h2c" "bin/"))))
    (inputs
     (list perl))
    (home-page "https://curl.se/h2c/")
    (synopsis "Convert HTTP headers to a curl command line")
    (description
     "Provided a set of HTTP request headers, h2c outputs how to invoke
curl to obtain exactly that HTTP request.")
    (license license:expat)))

(define-public coeurl
  (package
    (name "coeurl")
    (version "0.3.0")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://nheko.im/nheko-reborn/coeurl")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "1b435c2szwibm4i4r7mh22klyv9ncdkwkiy95p4xjfalsx4ripxh"))))
    (build-system meson-build-system)
    (native-inputs
     (list doctest pkg-config))
    (inputs
     (list curl libevent spdlog))
    (home-page "https://nheko.im/nheko-reborn/coeurl")
    (synopsis "Simple async wrapper around CURL for C++")
    (description "Coeurl is a simple library to do HTTP requests
asynchronously via cURL in C++.")
    (license license:expat)))

(define-public curlie
  (package
    (name "curlie")
    (version "1.6.9")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/rs/curlie")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32
         "1b94wfliivfq06i5sf664nhmp3v1k0lpz33cv9lyk6s59awb2hnw"))))
    (build-system go-build-system)
    (arguments
     `(#:import-path "github.com/rs/curlie"))
    (inputs
     (list curl go-golang-org-x-crypto go-golang-org-x-sys))
    (home-page "https://curlie.io")
    (synopsis "The power of curl, the ease of use of httpie")
    (description "If you like the interface of HTTPie but miss the features of
curl, curlie is what you are searching for.  Curlie is a frontend to
@code{curl} that adds the ease of use of @code{httpie}, without compromising
on features and performance.  All @code{curl} options are exposed with syntax
sugar and output formatting inspired from @code{httpie}.")
    (license license:expat)))
