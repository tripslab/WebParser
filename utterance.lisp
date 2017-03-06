(in-package :webparser)
(in-component :webparser)

(defstruct text-unit
  text ; input text
  component ; parser or texttagger
  interface-options ; extsformat, tagsformat, treecontents, treeformat, lfformat, debug
  texttagger-options ; see ../TextTagger/docs/README.xhtml
  parser-options ; see ../Parser/...
  extraction-options ; see ../NewIM/...
  requester ; :sender of the request to parse this utterance, :receiver of the ultimate response
  reply-id ; :reply-with/:in-reply-to
  debug-output-stream ; string-output-stream replacing *standard-output* while parsing
  texttagger-output ; word and prefer messages from TT
  parser-output
  )

(defstruct (utterance (:include text-unit))
  num ; utterance serial number
  )

(defstruct (paragraph (:include text-unit))
  (split-mode :split-clauses)
  uttnums
  ;; IM output
  extractions
  sentence-lfs
  )

(defun set-texttagger-options (opts)
  (unless (equalp '(ok)
	      (send-and-wait `(request :receiver TextTagger :content
		  (set-parameters ,@(substitute :default-type :tag-type opts)))))
    (format t "failed to set TextTagger options ~s~%" opts)))

;; we can't just set this in defsys because that's loaded before system.lisp
;; sets the parser options; instead we wait until we get the first request, and
;; then get the original settings before applying the settings from the request
(defun init-original-parser-options ()
  (unless *original-parser-options*
    (setf *original-parser-options* `(
        (parser::*semantic-skeleton-scoring-enabled*
	  ,parser::*semantic-skeleton-scoring-enabled*)
        ))))

(defun reset-parser-options ()
  (set-parser-options *original-parser-options*))

;; see also parser::initialize-settings in src/Parser/Trips-parser/messages.lisp
(defun set-parser-options (opts)
  (init-original-parser-options)
  (loop	for (k v) in opts
	do (eval `(setf ,k ',v))
	))

(defun reset-extraction-options ()
  (let ((peo *previous-extraction-options*))
    (setf *previous-extraction-options* nil)
    (set-extraction-options peo)
    (setf *previous-extraction-options* nil) ; don't back up
    ))

;; this bogosity to handle the absence of the IM package in the URCS web parser
(let ((im-pkg (find-package :im)))
  (if im-pkg
    (eval (read-from-string "

(defun set-extraction-options (opts)
  (when *previous-extraction-options* ;; automatically reset
    (reset-extraction-options))
  (setf *previous-extraction-options* `(
    :trace-level ,im::*trace-level*
    :rule-set nil
    :extraction-sequence ,im::*extraction-sequence*
    ))
  (setf im::*trace-level* (find-arg opts :trace-level))
  (let ((rule-set (find-arg opts :rule-set))
        (extraction-sequence (find-arg opts :extraction-sequence)))
    (cond
      (rule-set
        ;; NOTE: must re-load for every request, since the file may have changed
	(load (format nil *rule-set-path-format* rule-set))
	;; e.g. rule-set=\"foo\" => im::*es*='((im::fooruleset))
	(setf im::*extraction-sequence*
	      `((,(intern (format nil \"~:@(~a~)RULESET\" rule-set) :im))))
        )
      (extraction-sequence
        (setf im::*extraction-sequence* extraction-sequence))
      ))
  )

      "))
    ;; if no im-pkg
    (defun set-extraction-options (opts) (declare (ignore opts)) nil)
    ))

(defun send-utterance-to-system (utt)
  (setf (utterance-num utt) *last-uttnum*)
  ;; reset stuff throughout the system, including IM's utt record, which only
  ;; has room for 10,000 utterances
  (send-msg '(tell :content (start-conversation)))
  ;; make sure we know the default TT options
  (unless *original-tt-parameters*
    (setf *original-tt-parameters*
      (remove-arg
	  (cdr (send-and-wait
	      '(request :receiver TextTagger :content (get-parameters))))
	  ;; get-parameters returns this, but it can't be set using
	  ;; set-parameters, only init/fini
          :init-taggers)))
  ;; set TT options if they were given in the request
  (when (utterance-texttagger-options utt)
    (set-texttagger-options (utterance-texttagger-options utt)))
  ;; ditto parser/extraction options
  (set-parser-options (utterance-parser-options utt))
  (set-extraction-options (utterance-extraction-options utt))
  ;; make sure we get an end-of-turn message from IM
  ;; FIXME should we save the old value and restore it on end-of-turn?
  (eval (read-from-string "(setf im::*CPS-control* nil)"))

  ;; send the utterance itself off to be processed
  (send-msg `(tell :content (utterance :text ,(utterance-text utt) :uttnum ,(utterance-num utt) :direction input)))
  ;; set TT options back to the default if we changed them
  (when (utterance-texttagger-options utt)
    (set-texttagger-options *original-tt-parameters*))
  ;; parser/extraction options have to wait until the next text-unit is started
  )

;; without DrumGUI, just sending directly to TextTagger
(defun send-paragraph-to-system (para)
  (send-msg '(tell :content (start-conversation)))
  (set-parser-options (paragraph-parser-options para))
  (set-extraction-options (paragraph-extraction-options para))
  (let ((tt-reply
	  (send-and-wait `(request :receiver texttagger :content
	      (tag :text ,(paragraph-text para)
		   :imitate-keyboard-manager t
		   :next-uttnum ,*last-uttnum*
		   ,(paragraph-split-mode para) t
		   ,@(substitute :type :tag-type
		       (paragraph-texttagger-options para))
		   )))))
    (unless (eq 'ok (car tt-reply))
      (error "Bad reply from TextTagger: ~s" tt-reply))
    (setf (paragraph-uttnums para) (find-arg-in-act tt-reply :uttnums))
    (setf *last-uttnum* (car (last (paragraph-uttnums para))))
    )
  )

;; with DrumGUI
(defun send-paragraph-to-drum-system (para)
  ;; make sure we know the default TT options
  (unless *original-tt-parameters*
    (setf *original-tt-parameters*
      (remove-arg
	  (cdr (send-and-wait
	      '(request :receiver TextTagger :content (get-parameters))))
	  ;; get-parameters returns this, but it can't be set using
	  ;; set-parameters, only init/fini
          :init-taggers)))
  (unwind-protect ; reset TT options even if we get an error
    (progn ; protected form
      ;; set TT options if they were given in the request
      (when (paragraph-texttagger-options para)
	(set-texttagger-options (paragraph-texttagger-options para)))
      ;; ditto parser/extraction options
      (set-parser-options (paragraph-parser-options para))
      (set-extraction-options (paragraph-extraction-options para))
      (let ((dg-reply
	      (send-and-wait `(request :receiver drum :content
		  (load-text :text ,(paragraph-text para))))))
	(unless (eq 'result (car dg-reply))
	  (error "Bad reply from DrumGUI: ~s" dg-reply))
	(setf (paragraph-uttnums para) (find-arg-in-act dg-reply :uttnums))
	(setf (paragraph-extractions para) (find-arg-in-act dg-reply :extractions))
	(setf *last-uttnum* (car (last (paragraph-uttnums para))))
	)
      )
    ;; cleanup forms
    ;; set Parser/TT options back to the default if we changed them
    ;; (extraction options are reset automatically before the next set)
    (when (paragraph-parser-options para)
      (reset-parser-options))
    (when (paragraph-texttagger-options para)
      (set-texttagger-options *original-tt-parameters*))
    )
  )

(defun tag-text-using-texttagger (text)
  (send-msg '(tell :content (start-conversation)))
  (let ((tt-reply
	  (send-and-wait `(request :receiver texttagger :content
	      (tag :text ,(text-unit-text text)
		   ,@(when (paragraph-p text)
		     `(
		       :next-uttnum ,*last-uttnum*
		       ,(paragraph-split-mode text) t
		       ))
		   ,@(substitute :type :tag-type
		       (text-unit-texttagger-options text))
		   )))))
    ;; reply content should be a list of lists
    (unless (and (listp tt-reply) (every #'listp tt-reply))
      (error "Bad reply from TextTagger: ~s" tt-reply))
    (setf (text-unit-texttagger-output text) tt-reply)
    (when (paragraph-p text)
      (setf (paragraph-uttnums text)
        (remove-duplicates
	  (mapcar (lambda (msg) (second (member :uttnum msg))) tt-reply)
	  :test #'=))
      (setf *last-uttnum* (car (last (paragraph-uttnums text))))
      )
    (pop *pending-text-units*)
    (finish-text-unit text nil)
    )
  )

(defun send-text-to-system (text)
    (declare (type text-unit text))
  (incf *last-uttnum*)
  ;; start capturing debug output
  (setf *original-standard-output* *standard-output*)
  (setf *standard-output* (make-string-output-stream))
  (setf (text-unit-debug-output-stream text) *standard-output*)
  (ecase (text-unit-component text)
    (parser
      (etypecase text
	(utterance (send-utterance-to-system text))
	(paragraph
	  (if (eq :drum trips::*trips-system*)
	    (send-paragraph-to-drum-system text)
	    (send-paragraph-to-system text)
	    ))
	))
    (texttagger
      (tag-text-using-texttagger text))
    ))

(defun options-to-xml-attributes (text)
    (declare (type text-unit text))
  "Return a keyword argument list suitable for passing to print-xml-header
   representing the combined options from the given text-unit structure."
  (let* (
	 (tto (text-unit-texttagger-options text))
	 (tt (util:find-arg tto :tag-type))
	 (nsw (util:find-arg tto :no-sense-words))
	 (sofpp (util:find-arg tto :senses-only-for-penn-poss))
	 (po (text-unit-parser-options text))
	 (sss-pair (assoc 'parser::*semantic-skeleton-scoring-enabled* po))
	 (eo (text-unit-extraction-options text))
	 (rs (find-arg eo :rule-set))
	 (tl (find-arg eo :trace-level))
	 (io (text-unit-interface-options text))
	 )
    ;; when component=texttagger; get only the relevant interface options
    (when (eq 'texttagger (text-unit-component text))
      (setf io (nth-value 1 (util:remove-args io
          '(:stylesheet :tagsformat :debug)))))
    `(
      :component ,(text-unit-component text) ; not really an attribute, whatevs
      ,@io
      ,@(when tt
	 (list :tag-type (format nil "~(~s~)" tt)))
      ,@(when nsw (list :no-sense-words (format nil "~(~{~a~^,~}~)" nsw)))
      ,@(when sofpp
	(list :senses-only-for-penn-poss (format nil "~{~a~^,~}" sofpp)))
      ,@(when sss-pair
	(list :semantic-skeleton-scoring
	      (when (second sss-pair) (format nil "~a" (second sss-pair)))))
      ,@(when rs (list :rule-set rs))
      ,@(when tl (list :trace-level (format nil "~s" tl)))
      ,@(when (eq 'parser (text-unit-component text))
        `(
	  ;; list of available rule sets
	  ;; (not really an option, but it's easiest to put this here)
	  :rule-sets
	    ,(format nil "~{~a~^,~}" ; comma separated
	      (sort
		(mapcar
		  (lambda (p)
		    (let ((name (pathname-name p)))
		      ;; chop "RuleSet" off the end of name
		      (subseq name 0 (- (length name) 7))))
		  (directory (format nil *rule-set-path-format* "*")))
		#'string<))))
      )))

(defun reply-without-parsing (text &optional error-msg)
    (declare (type text-unit text))
  (let ((s (make-string-output-stream))
	(attrs (options-to-xml-attributes text)))
    (when error-msg
      (push error-msg attrs)
      (push :error attrs))
    (print-xml-header attrs nil s)
    (format-xml-end s 
      (ecase (text-unit-component text)
        (parser "trips-parser-output")
	(texttagger "texttagger-output")))
    (send-msg
      `(tell
	:receiver ,(text-unit-requester text)
	:in-reply-to ,(text-unit-reply-id text)
	:content
	  (http 200
	    :content-type "text/xml"
	    :content ,(get-output-stream-string s)
	    )))))

(defun receive-text-from-user (text)
    (declare (type text-unit text))
  (cond
    ((null (text-unit-text text))
      ; no input: just send header
      (reply-without-parsing text))
    ((every #'whitespace-char-p (text-unit-text text))
      ; almost no input
      (reply-without-parsing text "input was only whitespace"))
    ((>= (length (text-unit-text text)) (parser::getmaxchartsize))
      ; too much input
      (reply-without-parsing text (format nil "input too long (must be fewer than ~s characters)" (parser::getmaxchartsize))))
    (t ; have good input: queue it, and start working on it unless we're busy
      (let ((busy (not (null *pending-text-units*))))
	(setf *pending-text-units* (nconc *pending-text-units* (list text)))
	(unless busy
	  (send-text-to-system text))))
    ))

(defun speech-act-uttnum (sa)
  (if (eq (car sa) 'compound-communication-act)
    (speech-act-uttnum (car (find-arg-in-act sa :acts)))
    (find-arg-in-act sa :uttnum)
    ))

(defun finish-text-unit (text speech-act)
    (declare (type text-unit text))
  (reset-parser-options)
  (let ((s (make-string-output-stream)))
    ;; stop capturing debug output
    (setf *standard-output* *original-standard-output*)
    (parse-to-xml-stream
      (options-to-xml-attributes text)
      (text-unit-text text)
      (get-output-stream-string (text-unit-debug-output-stream text))
      (when (paragraph-p text)
        (paragraph-extractions text))
      speech-act
      nil ;trees
      (if (eq 'parser (text-unit-component text))
	;; using push reverses tt output lists, so we undo that here
	(reverse (if (paragraph-p text)
		   (mapcar #'reverse (text-unit-texttagger-output text))
		   (text-unit-texttagger-output text)))
	;; component=texttagger was never reversed in the first place
	(text-unit-texttagger-output text)
	)
      s)
    (send-msg
      `(tell
	:receiver ,(text-unit-requester text)
	:in-reply-to ,(text-unit-reply-id text)
	:content
	  (http 200
	    :content-type "text/xml; charset=utf-8"
	    :content ,(get-output-stream-string s)
	    )))
    (when *pending-text-units*
      (send-text-to-system (first *pending-text-units*)))
    ))

(defun find-utt-by-root (speech-acts root)
  "Given one of several varieties of collections of UTTs (including a single
   UTT), find the UTT with the given :root, if any. This includes UTTs whose
   root term is an SA-SEQ with :acts that include the given root ID."
  (cond
    ((consp (car speech-acts))
      (loop for sa in speech-acts
	    for found = (find-utt-by-root sa root)
	    when found return found
	    finally (return nil)))
    ((eq 'compound-communication-act (car speech-acts))
      (find-utt-by-root (find-arg-in-act speech-acts :acts) root))
    ((eq 'utt (car speech-acts))
      (let ((utt-root-id (find-arg-in-act speech-acts :root)))
	(if (eq root utt-root-id) ; simple case first
	  speech-acts
	  ; else test sa-seq :acts case
	  (let* ((terms (find-arg-in-act speech-acts :terms))
		 (utt-root-term
		   (find-arg-in-act
		       (find utt-root-id terms
			   :key (lambda (term) (find-arg-in-act term :var)))
		       :lf)))
	    (when (member root (find-arg (cdddr utt-root-term) :acts))
	      speech-acts))
	  )))
    ((eq 'failed-to-parse (car speech-acts))
      nil)
    (t
      (error "Expected list, 'UTT, 'COMPOUND-COMMUNICATION-ACT, or 'FAILED-TO-PARSE, but got ~s" (car speech-acts)))
    ))

(defun handle-sentence-lfs (msg args)
    (declare (ignore msg))
  (let ((content (find-arg args :content))
	(text (car *pending-text-units*)))
    (unless content
      (error "sentence-lfs missing :content"))
    (unless text
      (warn "received sentence-lfs with no text-units pending~%"))
    (when (typep text 'paragraph)
      ;; save the message for later; if we try to copy the :corefs over to
      ;; parser-output now, we risk a race condition between Parser and IM
      ;; outputs (we're not guaranteed to get them in an order that makes sense
      ;; from IM's perspective)
      (push content (paragraph-sentence-lfs text)))))

(defun apply-sentence-lfs (text)
    (declare (type paragraph text))
  (dolist (content (paragraph-sentence-lfs text))
    (destructuring-bind (_ &key roots terms &allow-other-keys) content
        (declare (ignore _))
      (when (and terms (null roots))
	(error "Terms but no roots in sentence-lfs message"))
	     ;; get the relevant LFs from the new-speech-act(-hyps) messages
      (let* ((nsas (paragraph-parser-output text))
	     (utts (mapcar (lambda (root)
			     (or (find-utt-by-root nsas root)
				 (error "Can't find utt with root/act ~s; parser output was:~%~s" root nsas)))
			   roots))
	     (term-lfs (mapcan (lambda (utt)
				 (mapcar (lambda (term)
					   (find-arg-in-act term :lf))
					 (find-arg-in-act utt :terms)))
			       utts)))
	;; add the :coref arguments from the terms in the sentence-lfs
	;; message, destructively, to the corresponding terms we already
	;; stored
	(dolist (term terms)
	  (destructuring-bind (_ var __ &key coref &allow-other-keys) term
	      (declare (ignore _ __))
	    (when coref
	      (let ((lf (find var term-lfs :key #'second)))
		(unless lf
		  (error "Can't find term ~s to add :coref ~s to" var coref))
		(rplacd (last lf) (list :coref coref))
		))))))))

(defun handle-new-speech-act (msg args)
    (declare (ignore msg))
  (let* ((speech-act (first args)) ; get lf from message args
         (sa-uttnum (speech-act-uttnum speech-act))
	 ;; this doesn't work when processing a paragraph; instead we get trees
	 ;; from the utts now that that actually has all the trees and not just
	 ;; the first
         ;(trees (subst-package (show-trees) :parser)) ; get trees directly from parser via library call
	 (text (car *pending-text-units*)))
    (etypecase text
      (utterance
	(cond
	  ((null sa-uttnum)
	    (warn "no uttnum in new-speech-act"))
	  ((not (eql (utterance-num text) sa-uttnum))
	    (error "uttnum mismatch; expected ~s but got ~s in new-speech-act" (utterance-num text) sa-uttnum))
	  )
	(setf (utterance-parser-output text) speech-act)
	)
      (paragraph
        (push speech-act (paragraph-parser-output text))
        )
      (null
        (warn "got new-speech-act with no pending text-units"))
      )))

(defun handle-paragraph-completed (msg args)
    (declare (ignore msg args)) ; TODO check whether :id matches start-paragraph/end-paragraph's
  (unless (eq :step trips::*trips-system*) ; need to wait for IM in STEP
    (let ((para (pop *pending-text-units*)))
      (etypecase para
	(paragraph
	  (finish-text-unit para (reverse (paragraph-parser-output para))))
	(utterance
	  (error "received unexpected paragraph-completed message when the first pending text-unit was an utterance, not a paragraph"))
	(null
	  (warn "got paragraph-completed with no pending text-units"))
	))))

(defun handle-paragraph-done (msg args)
    (declare (ignore msg args)) ; TODO check whether :id matches start-paragraph/end-paragraph's
  (when (eq :step trips::*trips-system*) ; handled earlier in other sys
    (let ((para (pop *pending-text-units*)))
      (etypecase para
	(paragraph
	  (handler-case (apply-sentence-lfs para)
	    (error (e) (warn "apply-sentence-lfs failed: ~a" e)))
	  (finish-text-unit para (reverse (paragraph-parser-output para))))
	(utterance
	  (error "received unexpected paragraph-done message when the first pending text-unit was an utterance, not a paragraph"))
	(null
	  (warn "got paragraph-done with no pending text-units"))
	))))

(defun handle-turn-done (msg args)
    (declare (ignore args))
  (let ((utt (first *pending-text-units*)))
    (etypecase utt
      (paragraph
        nil) ; ignore
      (utterance
        (pop *pending-text-units*)
	(finish-text-unit utt (utterance-parser-output utt))
	)
      (null
        (warn "got ~s with no pending text-units"
	      (car (find-arg-in-act msg :content))))
      )))

;; FIXME? I'm not sure WebParser is guaranteed to receive TT output messages
;; before the corresponding Parser output message, but this assumes it. If it
;; happens the other way around, we might send a response without some
;; TextTagger output, pop the pending text-unit, and then get errors when this
;; function is finally called.
(defun handle-texttagger-output (msg args)
  "Save content of word, prefix, and prefer messages from TextTagger in the current utterance struct."
  (let ((uttnum (find-arg (cdr args) :uttnum))
        (text (car *pending-text-units*)))
    (unless uttnum
      (error "TT msg has no uttnum. msg=~s; args=~s" msg args))
    (etypecase text
      (null
	(warn "got TT output for uttnum ~s, but no utts are pending" uttnum))
      (utterance
	(unless (utterance-num text)
	  (error "pending utt has no uttnum"))
	(unless (eql uttnum (utterance-num text))
	  (error "TT msg uttnum ~s failed to match pending utt uttnum ~s" uttnum (utterance-num text)))
	(push (find-arg-in-act msg :content) (text-unit-texttagger-output text))
	)
      (paragraph
        (unless (paragraph-uttnums text)
	  (error "pending paragraph has no uttnums"))
	(unless (member uttnum (paragraph-uttnums text))
	  (error "TT msg uttnum ~s failed to match any of the uttnums in the pending paragraph: ~s" uttnum (paragraph-uttnums text)))
	(push (find-arg-in-act msg :content)
	      (car (text-unit-texttagger-output text)))
	)
      )
    ))

(defun handle-started-speaking-from-texttagger (msg args)
  (let ((uttnum (find-arg args :uttnum))
        (text (car *pending-text-units*)))
    (unless uttnum
      (error "started-speaking msg has no uttnum. msg=~s; args=~s" msg args))
    (etypecase text
      (null
	(warn "got started-speaking for uttnum ~s, but no utts are pending" uttnum))
      (utterance
	(unless (utterance-num text)
	  (error "pending utt has no uttnum"))
	(unless (eql uttnum (utterance-num text))
	  (error "started-speaking uttnum ~s failed to match pending utt uttnum ~s" uttnum (utterance-num text)))
	; TODO add this to texttagger-output slot?
        )
      (paragraph
        (unless (paragraph-uttnums text)
	  (error "pending paragraph has no uttnums"))
	(unless (member uttnum (paragraph-uttnums text))
	  (error "TT msg uttnum ~s failed to match any of the uttnums in the pending paragraph: ~s" uttnum (paragraph-uttnums text)))
	(push nil ; TODO or (list (find-arg-in-act msg :content)) ?
	      (text-unit-texttagger-output text)))
      )
    ))

;(defun handle-utterance-from-texttagger (msg args)
;  ; TODO ?
;  )
