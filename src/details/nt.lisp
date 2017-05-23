(defpackage py.path.details.nt
  (:use :cl :alexandria)
  (:shadowing-import-from py.path.details.generic
                          getenv concat)
  (:export splitdrive
           split
           splitunc
           isabs
           normcase
           basename
           dirname
           islink
           ismount
           join
           expanduser
           expandvars))

(in-package py.path.details.nt)

(define-constant +separator+  #\\)
(define-constant +posix-separator+ #\/)
(define-constant +unc-prefix+ "//" :test #'equal)
(define-constant +path-separator+ #\;)


(defun posixify (path)
  "Replaces '\\' with '/' in path"
  (substitute +posix-separator+ +separator+ path))

(defun splitdrive (path)
  "Split a path to the drive (with letter) and path after drive.
Example:
  (splitdrive \"C:\\Sources\\lisp\")
  => (\"C:\" \"\\Sources\\lisp\")
This function also parses the UNC paths, providing \\\\hostname\\mountpoint
as a drive part."
  (let ((norm (posixify path)))
    (cond ((and (> (length path) 1)     
                (char= (char norm 1) #\:)) ; paths starting with "X:"
           (cons (subseq path 0 2)
                 (subseq path 2)))
          ((starts-with-subseq +unc-prefix+ norm) ; paths starting with "//"
		   ;; find first slash position after the prefix (like \\host\sharename)
           (if-let ((pos (position +posix-separator+ norm :start 2)))
			 ;; if found, find the next slash position (like \\host\sharename\dir)
			 (if-let ((pos1 (position +posix-separator+ norm :start (1+ pos))))
			   ;; extract the path around this last slash
                 (cons (subseq path 0 pos1)
                       (subseq path pos1))
                 (cons path ""))
             (cons "" path)))
          (t (cons "" path)))))


(defun split (path)
  "Split a path to the pair (head . tail) where head is everything before
the last '/' and tail is after the last '/'.
The slashes are stripped from the head and tail.
If the head is a drive name, the slashes are not stripped from it."
  (flet ((sep-p (c) (or (char= c +separator+) (char= c +posix-separator+))))
    (destructuring-bind (drive . p) (splitdrive path)
      (let* ((i (position-if #'sep-p p :from-end t)) ; position of the last slash
             (ni (if i (1+ i) 0))			   ; position after last slash
             ;; split to head and tail at the position after the last slash
             (head (subseq p 0 ni))
             (tail (subseq p ni))
             ;; position in the head of first non-separator
             (j (position-if-not #'sep-p head :from-end t))) 
        (cons (concat drive
					  (if (and j (> j 0)) (subseq head 0 (1+ j)) head))
              tail)))))


(defun splitunc (path)
  "Split a pathname with UNC path. UNC syntax:
\\\\host-name\\share-name\\file_path
Return a cons pair (\\\\host-name\\share-name . \\file_path)"
  (let ((norm (posixify path))
		pos
		pos1)
	(when (not (starts-with-subseq +unc-prefix+ norm))
	  ;; paths must start with "//"
	  (return-from splitunc (cons "" path)))
	(unless (setq pos (position +posix-separator+ norm :start 2))
	  ;; second '/' must exists
	  (return-from splitunc (cons "" path)))
	(when (= pos 2)
	  ;; and it is not 3 in the row at the beginning
	  (return-from splitunc (cons "" path)))
	;; if directory component exists
	(cond ((and (setq pos1 (position +posix-separator+ norm :start (1+ pos)))
				(/= (1+ pos) pos1)) ;; and it is not not 2 slashes in the second component
		   ;; extract the path around this last slash
		   (cons (subseq path 0 pos1)
				 (subseq path pos1)))
		  ((not pos1)					; no directory component exist, return unc
		   (cons path ""))
		  (t 
		   ;; otherwise head is empty but tail is the path given
		   (cons "" path)))))

(declaim (inline separator-p))
(defun separator-p (c)
  "Return t if C is a separator. C should be a character"
  (or (char= c +separator+) (char= c +posix-separator+)))


(defun starts-with-slash (path)
  "Return t if the PATH starts with either forward or backward slash"
  (and (> (length path) 0)
	   (let ((c (char path 0)))
		 (separator-p c))))


(defun ends-with-slash (path)
  "Return t if the PATH ends with either forward or backward slash"
  (and (> (length path) 0)
	   (let ((c (last-elt path)))
		 (or (char= c +separator+) (char= c +posix-separator+)))))


(defun isabs (path)
  "Return t if the path is absolute."
  (destructuring-bind (drive . p) (splitdrive path)
    (declare (ignore drive))
    (and (not (emptyp p))
		 (starts-with-slash p))))


(defun normcase (path)
  "Replace slash with backslahes and lowers the case of the string"
  (string-downcase (posixify path)))


(defun basename (path)
  "Returns filename portion of path"
  (cdr (split path)))


(defun dirname (path)
  "Returns directory portion of path"
  (car (split path)))


(defun islink (path)
  "Test if the path is a symbolic link. Returs falso on Win32"
  (declare (ignore path))
  nil)


(defun ismount (path)
  "Test if the path is a mount point. For local paths it should be
absolute path, for UNC it should be mount point of the host"
  (destructuring-bind (unc . p) (splitunc path)
    (if (not (emptyp unc))
        (or (emptyp p)
            (string= p "/")
            (string= p "\\"))
        (destructuring-bind (drive . p) (splitdrive path)
          (declare (ignore drive))
          (or (string= p "/")
              (string= p "\\"))))))


(defun join (path &rest paths)
  "Join paths provided, merging (if absolute) and
inserting missing separators.
Examples:
  (join \"a/b\" \"x/y\")
=> \"a/b\\\\x/y\"
  (join \"c:\\\\hello\" \"world/test.txt\")
=> \"c:\\\\hello\\\\world/test.txt\""
  (destructuring-bind (drive1 . p1) (splitdrive path)
    ;; do iterations
    ;; when drive and path are not empty but path doesn't start wit slash
    (destructuring-bind (drive . p)
        (join-iter drive1 p1 paths)
      (if (and (not (emptyp p))
               (not (starts-with-slash p))
               (not (emptyp drive))
               (char/= (last-elt drive) #\:))
          (concat drive (string +separator+) p)
          (concat drive p)))))
			 


(defun join-iter (drive1 p1 paths)
  "Helper function for recursive concatenation of paths.
PATHS is a list of rest paths, drive1 and p1 split first path"
  (flet ((samedrive (d1)
           (string= (normcase d1) (normcase drive1)))
         (concat-paths (p1 p2)
           (if (and (> (length p1) 0) (not (ends-with-slash p1)))
               (concat p1 "\\" p2)
               (concat p1 p2))))
    (if (null paths)
        (cons drive1 p1)	; degraded case
        ;; Normal case. get drive and path components of the each of paths	  
        (destructuring-bind (drive . p) (splitdrive (car paths))
          ;; if this path is absolute or the original path is not absolute
          (cond ((and (starts-with-slash p)
                      (or (not (emptyp drive))
                          (emptyp drive1)))
                 ;; continue iteration taking new drive				 
                 (join-iter drive p (cdr paths)))
                ;; otherwise use original drive
                ((starts-with-slash p)
                 (join-iter drive1 p (cdr paths)))
                ;; different drives, including unc
                ((and (not (emptyp drive))
                      (not (string= drive drive1)) ; different drives
                      (not (samedrive drive)))
                 (join-iter drive p (cdr paths)))
                ((and (not (emptyp drive))
                      (not (string= drive drive1))) ; different case of drives, use new
                 (join-iter drive (concat-paths p1 p) (cdr paths)))
                (t
                 ;; relative paths, use old drive and concatenate paths as needed
                 (join-iter drive1 (concat-paths p1 p) (cdr paths))))))))


(defun expanduser (path)
  "Expand paths starting with ~ and ~user.
~ - home directory
~user - user's home directory"
  (unless (and (not (emptyp path))
               (char= (char path 0) #\~))
    (return-from expanduser path))
  ;; starts with ~. Let's find first after slash
  (let ((first-slash
         (or 
          (position-if #'separator-p path :start 1)
          (length path)))
        (home
         (cond ((not (emptyp (getenv "HOME")))
                (getenv "HOME"))
               ((not (emptyp (getenv "USERPROFILE")))
                (getenv "USERPROFILE"))
               ;; no homepath variable - return original path
               ((emptyp (getenv "HOMEPATH"))
                (return-from expanduser path))
               (t (join (or (getenv "HOMEDRIVE") "") (getenv "HOMEPATH"))))))
    (concat
     ;; if the path starts with i.e. "~user", take the directory above current
     ;; user's home directory and use "user" instead of user's directory
     ;; i.e. C:\\Users\\alexeyv -> C:\\Users\\user
     (if (> first-slash 1) (join (dirname home) (subseq path 1 first-slash)) home)
     ;; and concatenate it with the rest of the path
     (subseq path first-slash))))

	
(defun expandvars (path)
  "Expand environment variables in the path.
Variables could be written as $var, ${var}, %var%.
The variables inside single quotes are not expanded,
and $$ and %% translated to $ and % accordingly"
  (declare (optimize (debug 3) (speed 0) (safety 3)))
  (unless (and (not (emptyp path))
               (or (find #\$ path)
                   (find #\% path)))
    (return-from expandvars path))
  (loop
     with res = ""
     with i = 0
     with len = (length path)
     with last = (1- len)
     while (< i len)
     for c = (char path i)
     do
       (macrolet ((acc (var &rest vars)
                    `(setf res (concat res ,var ,@vars))))
         (case c
           (#\'							; single quote
            (let ((next-quote (or (position #\' path :start (1+ i)) len)))
              (acc (subseq path i (min (1+ next-quote) len)))
              (setf i next-quote)))
           (#\%
            ;; look for doubles: %%
            (if (and (< i last) (char= (char path (1+ i)) #\%))
                (progn (acc c) (incf i))
                ;; looking for next %
                (let ((next-% (position #\% path :start (1+ i))))
                  (if (not next-%)      ; not found, return all the rest
                      (setf res (concat res (subseq path i))
                            i last)
                      ;; found
                      (let ((var (subseq path (1+ i) next-%)))
                        (acc (if (getenv var) (getenv var) (concat "%" var "%")))
                        (setf i next-%))))))
           (#\$
            ;; look for doubles: $$
            (cond ((and (< i last) (char= (char path (1+ i)) #\$))
                   (acc c) (incf i))
                  ;; looking for ${var} constructions
                  ((and (< i last) (char= (char path (1+ i)) #\{))
                   (if-let (end-of-var (position #\} path :start (+ 2 i)))
                     ;; extract variable from {}
                     (let ((var (subseq path (+ 2 i) end-of-var)))
                       (acc (if (getenv var) (getenv var) (concat "$" var)))
                       (setf i  end-of-var))
                     ;; no closing "}" found
                     (setf res (concat res (subseq path i)) 
                           i last)))
                  ;; all other cases: $var and alike
                  (t                    
                   (let* ((end-of-var (or (position-if-not #'alphanumericp path :start (1+ i)) len))
                          (var (subseq path (1+ i) end-of-var)))
                     (acc (if (getenv var) (getenv var) (concat "$" var)))
                     (setf i (1- end-of-var))))))
           ;; not special character, just accumulate it
           (otherwise (acc c))))
       (incf i)
     finally (return res)))
	   



  
