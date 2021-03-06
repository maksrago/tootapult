;;;; functions pertaining to posts

(in-package :tootapult)

(defun get-words (text)
  "properly splits a toot up into words, preserving newlines"
  (reverse
    (loop
       with words = ()
       with cur-start = 0
				   
       if (< cur-start (length text))
       do
	 (let ((s (search " " text :test #'string= :start2 cur-start)))
	   (setf cur-start
		 (if s
		     (prog1 (1+ s)
		       (push (str:substring cur-start s text) words))
		     (prog1 (length text)
		       (push (str:substring cur-start (length text) text)
			     words)))))
       else
       return words)))

(defun self-reply-p (status)
  "checks if STATUS is a self-reply"
  (let ((is-reply (agetf status :in--reply--to--id)))
    (cond
      ((and is-reply (equal (agetf status :in--reply--to--account--id)
			    *mastodon-account-id*))
       t)
      ((not is-reply) t)
      (t nil))))

(defun should-crosspost-p (status)
  "checks if we should crosspost the status"
  (let ((filtered (or (filter-present-p (agetf status :content))
		      (filter-present-p (agetf status :spoiler--text))))
	(mentions (agetf status :mentions))
	(is-reply (agetf status :in--reply--to--id)))
    (and (member (agetf status :visibility) *privacy-level* :test #'string=)
	 (or *crosspost-mentions* (null mentions))
	 (not filtered)
	 (or (not is-reply)
	     (self-reply-p status)))))

(defun filter-present-p (status-text)
  "checks if any filter words appear in STATUS-TEXT"
  (loop
     for f in *filters*

     when (containsp f status-text :ignore-case t)
     return t))

(defun sanitize-content (post)
  "removes all html tags from POST

returns a list of each newline-separated paragraph"
  (remove-if #'blankp
	     (flatten
	      (loop
		 with content
		 for c across (plump:children (plump:parse (html-entities:decode-entities post)))
		 do (push (loop
			   for c1 across (plump:children c)
			   collect (plump:text c1))
			  content)
		 finally (return (reverse content))))))

(defun replace-all-mentions (mentions content)
  "replaces all @mentions in CONTENT with URL to account"
  (let ((fixed-content content))
    (dolist (mtn mentions fixed-content)
      (setf fixed-content
	    (replace-all (concatenate 'string "@" (first (split #\@ (agetf mtn :acct))))
			 (agetf mtn :url)
			 fixed-content)))))

(defun build-post (status)
  "builds post from status for crossposting

adds CW, if needed
sanitizes html tags
replaces mentions, if specified"
  (let ((cw (agetf status :spoiler--text))
	(mentions (agetf status :mentions))
	(content (format nil "~{~A~^~%~}" (sanitize-content (agetf status :content)))))

    (concatenate 'string
		 (unless (blankp cw) (format nil "cw: ~A~%~%" cw))
		 (if (and *crosspost-mentions*
			  mentions)
		     (replace-all-mentions mentions content)
		     content))))

(defun get-post-media (media-list)
  "downloads all media in MEDIA-LIST"
  (remove-if #'null
	     (mapcar (lambda (attachment)
		       (download-media (agetf attachment :url)))
		     media-list)))

(defun download-media (url)
  "downloads URL to a generated filename.
returns the filename"
  (let ((filename (merge-pathnames (concatenate 'string
						(symbol-name (gensym "ATTACHMENT-"))
						"."
						(pathname-type url))
				   (temporary-directory))))
    (if (member (pathname-type url) *crosspostable-file-types* :test #'string=)
	(handler-case
	    (progn
	      (when (log:info)
		(log:info "downloading" url "to" "filename"))
  
	      (dex:fetch url filename)
	      filename)
	  (error (e)
	    (log:error "experienced error" e "downloading" url)
	    nil))
	(log:warn "cannot crosspost file of type" (pathname-type url)))))

(defun clean-downloads (files)
  "deletes all FILES we downloaded to crosspost"
  (mapcar #'uiop:delete-file-if-exists files)
  nil)
