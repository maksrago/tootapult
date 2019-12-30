;;;; tootapult.lisp

(in-package #:tootapult)

(defvar *max-tweet-length* 280)
(defvar *privacy-values* '("direct" "private" "unlisted" "public"))
(defvar *map-filename* "posts.map")

(defvar *mastodon-instance*)
(defvar *mastodon-account-id*)
(defvar *mastodon-token*)
(defvar *privacy-level*)
(defvar *crosspost-mentions*)
(defvar *websocket-client*)

;; these need 'nil' because otherwise they cant be evaluated, period
(defvar *id-mappings* nil)
(defvar *filters* nil)

(defun main ()
  "binary entry point"
  (let ((exit-status 0))
    (handler-case
	(with-user-abort
	  (load-config)
	  (import-id-map)
	  (start-crossposter)
	  (loop while (eql (ready-state *websocket-client*) :open) do (sleep 2)))
      (user-abort ()
	(format t "shutting down~%"))
      (error (e)
	(format t "encountered error: ~a~%" e)
	(setf exit-status 1)))

    (when *id-mappings*
      (export-id-map))
    
    (uiop:quit exit-status)))

(defun start-crossposter ()
  "starts streaming from the mastodon endpoint, handling new events as the arise"
  (unless (chirp:account/verify-credentials)
    (error "incorrect twitter credentials"))

  (setf *websocket-client*
	(make-client (format nil "~a/api/v1/streaming?access_token=~a&stream=user"
			     (get-mastodon-streaming-url)
			     *mastodon-token*)))

    (wsd:on :open *websocket-client*
	    #'print-open)
    (wsd:on :message *websocket-client*
	    #'process-message)
    (wsd:on :close *websocket-client*
	    #'print-close)

    (wsd:start-connection *websocket-client*))

(defun process-message (message)
  "processes our incoming websocket message"
  (let ((parsed (decode-json-from-string message)))
    (dispatch (agetf parsed :event) (agetf parsed :payload))))

(defun print-open ()
  "prints a message when the websocket connection opens"
  (format t "websocket connection open~%"))

(defun print-close (&key code reason)
  "prints a message when the websocket closes, printing the reason and code"
  (when (and code reason)
    (format t "websocket closed because '~a' (code=~a)~%" reason code)))


#|

event-types: update, delete, notification
data: json post object, status id, json notification object

|#
  
(defun dispatch (event-type data)
  "calls different functions with DATA depending on what EVENT-TYPE we recieved"
  (let ((parsed-data (decode-json-from-string data)))
    (cond
      ;; if its a new status
      ;;    the posting account is ours
      ;;    and its not a reblog
      ;;  crosspost it
      ((and (string= event-type "update")
	    (equal (agetf (agetf parsed-data :account) :id) *mastodon-account-id*)
	    (null (agetf parsed-data :reblog))
	    (should-crosspost-p parsed-data))
       (post-to-twitter parsed-data))

      ;; if its a delete event, and we have the id stored somewhere
      ;;  delete it
      ((and (string= event-type "delete")
	    (member data *id-mappings* :key #'car :test #'equal))
       (delete-post data))

      ;; if we dont know what the event is, ignore it :3
      (t nil))))

;;  clean doesnt properly handle newlines, so thats gonna be something
;;  im probably going to have to do
(defun post-to-twitter (status)
  ;; this loop macro is bad and i feel bad writing it.
  ;; should be split into PROPER lisp code lol
  (loop
     with tweet-length = 0

     with tweet-words = (get-words (build-post status))
     with tweet = nil
     with last-id = (cdr (find (agetf status :in--reply--to--id nil) *id-mappings*
			       :test #'equal :key #'car :from-end t))
     with media-list = (get-post-media (agetf status :media-attachments))
       
     while tweet-words
     do
       (push (pop tweet-words) tweet)
       (setf tweet-length (chirp:compute-status-length (join " " tweet)))
       
     when (> tweet-length *max-tweet-length*)
     do
       (push (pop tweet) tweet-words)
       (setf last-id (slot-value (chirp:tweet (join " " (reverse tweet))
					      :reply-to last-id
					      :file media-list)
				 'chirp::%id)
	     media-list nil
	     tweet nil
	     *id-mappings* (append *id-mappings*
				   `((,(agetf status :id) . ,last-id))))
       
     finally
       (when tweet
	 (setf *id-mappings*
	       (append *id-mappings*
		       `((,(agetf status :id) . ,(slot-value (chirp:tweet (join " " (reverse tweet))
									  :reply-to last-id
									  :file media-list)
							     'chirp::%id))))))))

(defun build-post (status)
  "builds post from status for crossposting

adds CW, if needed
sanitizes html tags
replaces mentions, if specified"
  (let ((cw (agetf status :spoiler--text))
	(mentions (agetf status :mentions))
	(content (format nil "~{~A~^~%~}" (sanitize-content (agetf status :content)))))
    (labels ((replace-mentions (m)
	       (let ((handle (concatenate 'string "@"
					  (first
					   (split #\@ (agetf m :acct))))))
		 (replace-all handle (agetf m :url) content))))

      (concatenate 'string
		   (unless (blankp cw) (format nil "cw: ~A~%~%" cw))
		   (if *crosspost-mentions*
		       (mapcar #'replace-mentions mentions)
		       content)))))

(defun get-post-media (media-list)
  "downloads all media in MEDIA-LIST"
  (mapcar (lambda (attachment)
	    (download-media (agetf attachment :url)))
	  media-list))

(defun download-media (url)
  "downloads URL to a generated filename.
returns the filename"
  (let ((filename (merge-pathnames (concatenate 'string
						(symbol-name (gensym "ATTACHMENT-"))
						(pathname-type url))
				   (temporary-directory))))
    (handler-case
	(dex:fetch url filename)
      (error ()
	nil))
    filename))

(defun delete-post (id)
  ;; get all of our mapped tweet ids
  (let ((tweet-ids (loop
		      for (key . value) in *id-mappings*

		      when (equal key id)
		      collect value)))
    
    ;; delete all of them from twitter
    (mapcar #'chirp:statuses/destroy tweet-ids)

    ;; and them remove them from our mappings
    (setf *id-mappings* (remove id *id-mappings* :test #'equal :key #'car))))
