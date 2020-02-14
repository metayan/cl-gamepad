#|
 This file is a part of cl-gamepad
 (c) 2020 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.fraf.gamepad.impl)

(defvar *hid-manager*)
(defvar *run-loop-mode*)
(defvar *device-table* (make-hash-table :test 'eql))
(defvar *event-handler*)

(defun one-of (thing &rest choices)
  (member thing choices))

(define-compiler-macro one-of (thing &rest choices)
  (let ((thingg (gensym "THING")))
    `(let ((,thingg ,thing))
       (or ,@(loop for choice in choices
                   collect `(eql ,choice ,thingg))))))

(cffi:defcallback device-match :void ((user :pointer) (result io-return) (sender :pointer) (dev :pointer))
  (declare (ignore user result sender))
  (ensure-device dev))

(cffi:defcallback device-remove :void ((user :pointer) (result io-return) (sender :pointer) (dev :pointer))
  (declare (ignore user result sender))
  (let ((device (gethash (cffi:pointer-address dev) *device-table*)))
    (when device
      (close-device device))))

(cffi:defcallback device-changed :void ((dev :pointer) (result io-return) (sender :pointer) (value :pointer))
  (declare (ignore result sender))
  (let ((device (gethash (cffi:pointer-address dev) *device-table*)))
    (when device
      (handle-event device value))))

(defclass device (gamepad:device)
  ((dev :initarg :dev :reader dev)
   (run-loop-mode :initarg :run-loop-mode :reader run-loop-mode)))

(defun create-device-from-dev (dev)
  (let* ((product-key (device-property dev PRODUCT-KEY))
         (name (if (or (cffi:null-pointer-p product-key)
                       (/= (string-type-id) (type-id product-key)))
                   "[Unknown]"
                   (cfstring->string product-key)))
         (mode (create-string name)))
    (register-value-callback dev (cffi:callback device-changed) dev)
    (device-unschedule-from-run-loop dev (get-current-run-loop) *run-loop-mode*)
    (device-schedule-with-run-loop dev (get-current-run-loop) mode)
    (make-instance 'device
                   :dev dev
                   :run-loop-mode mode
                   :name name
                   :vendor (device-int-property dev VENDOR-ID-KEY)
                   :product (device-int-property dev PRODUCT-ID-KEY)
                   :version (device-int-property dev VERSION-NUMBER-KEY)
                   :driver :iokit)))

(defun handle-event (device value)
  (let* ((element (value-element value))
         (time (value-timestamp value))
         (int (value-int-value value))
         (page (element-page element))
         (code (logior (element-page-usage element)
                       (ash (cffi:foreign-enum-value 'io-page page) 16))))
    (case (element-type element)
      (:input-button
       (let ((label (gethash code (button-map device))))
         (if (< 0 int)
             (queue-push (gamepad::make-button-down device time code label) queue)
             (queue-push (gamepad::make-button-up device time code label) queue))))
      ((:input-axis :input-misc)
       ;; Ignore weird pages that get sent for input-misc.
       (when (one-of page :generic-desktop :simulation :vr :game :button)
         (let* ((min (element-logical-min element))
                (max (element-logical-max element))
                (range (- max min))
                (axis-map (axis-map device)))
           (case (element-usage element)
             (:hat-switch
              (let ((x 0f0) (y 0f0)
                    ;; Remap hats to cover two codes
                    (xc (logior (+ 0 (* 2 (element-page-usage element)))
                                (ash (cffi:foreign-enum-value 'io-page page) 16)))
                    (yc (logior (+ 1 (* 2 (element-page-usage element)))
                                (ash (cffi:foreign-enum-value 'io-page page) 16))))
                ;; If within range, the value is a an 8-valued angle starting from north, going clockwise.
                (when (<= int range)
                  (let ((dir (round (* int 8) (1+ range))))
                    (case dir
                      ((1 2 3) (setf x +1f0))
                      ((5 6 7) (setf x -1f0)))
                    (case dir
                      ((0 1 7) (setf y +1f0))
                      ((3 4 5) (setf y -1f0)))))
                (funcall *event-handler* (gamepad::make-axis-move device time xc (gethash xc axis-map) x))
                (funcall *event-handler* (gamepad::make-axis-move device time yc (gethash yc axis-map) y))))
             (T
              (let ((value (1- (* (/ (- (cond ((< int min) min) ((< max int) max) (T int)) min)
                                     range)
                                  2f0))))
                (funcall *event-handler* (gamepad::make-axis-move device time code (gethash code axis-map) value)))))))))))

(defun ensure-device (dev)
  (or (gethash (cffi:pointer-address dev) *device-table*)
      (setf (gethash (cffi:pointer-address dev) *device-table*)
            (create-device-from-dev dev))))

(defun close-device (device)
  (device-unschedule-from-run-loop (dev device) (get-current-run-loop) (run-loop-mode device))
  (remhash (cffi:pointer-address (dev device)) *device-table*)
  (slot-makunbound device 'dev))

(defun refresh-devices ()
  (let ((to-delete (list-devices)))
    (with-cf-objects ((set (manager-device-set *hid-manager*)))
      (let ((size (set-get-count set)))
        (cffi:with-foreign-object (devices :pointer size)
          (set-get-values set devices)
          (loop for i from 0 below size
                for dev = (cffi:mem-aref devices :pointer i)
                do (setf to-delete) (delete (ensure-device dev) to-delete)))))
    (mapc #'close-device to-delete)
    (list-devices)))

(defun init ()
  (cffi:use-foreign-library corefoundation)
  (cffi:use-foreign-library iokit)
  (unless (boundp '*run-loop-mode*)
    (setf *run-loop-mode* (create-string "device-run-loop")))
  (unless (boundp '*hid-manager*)
    (with-cf-objects ((n1 (create-number :int32 (cffi:foreign-enum-value 'io-page :generic-desktop)))
                      (n2 (create-number :int32 (cffi:foreign-enum-value 'io-desktop-usage :joystick)))
                      (n3 (create-number :int32 (cffi:foreign-enum-value 'io-desktop-usage :gamepad)))
                      (n4 (create-number :int32 (cffi:foreign-enum-value 'io-desktop-usage :multi-axis-controller)))
                      (d1 (create-dictionary (list (cons DEVICE-USAGE-PAGE-KEY n1) (cons DEVICE-USAGE-KEY n2))))
                      (d2 (create-dictionary (list (cons DEVICE-USAGE-PAGE-KEY n1) (cons DEVICE-USAGE-KEY n3))))
                      (d3 (create-dictionary (list (cons DEVICE-USAGE-PAGE-KEY n1) (cons DEVICE-USAGE-KEY n4))))
                      (a (create-array (list d1 d2 d3))))
      (let ((manager (create-hid-manager (cffi:null-pointer) 0)))
        (setf *hid-manager* manager)
        (set-matching-multiple manager a)
        (register-device-match-callback manager (cffi:callback device-match) (cffi:null-pointer))
        (register-device-remove-callback manager (cffi:callback device-remove) (cffi:null-pointer))
        (open-manager manager 0)
        (manager-schedule-with-run-loop manager (get-current-run-loop) *run-loop-mode*)
        (run-loop *run-loop-mode* 0d0 T)
        (refresh-devices)))))

(defun shutdown ()
  (when (boundp '*hid-manager*)
    (let ((manager *hid-manager*))
      (makunbound *hid-manager*)
      (manager-unschedule-from-run-loop manager (get-current-run-loop) (cffi:null-pointer))
      (mapc #'close-device (list-devices))
      (close-manager manager 0)
      (release manager)
      T)))

(defun list-devices ()
  (loop for v being the hash-values of *device-table* collect v))

(defun call-with-polling (function mode timeout)
  (let ((s (etypecase timeout
             ((eql NIL) 0d0)
             ((eql T) 1d0)
             ((real 0) (float timeout 0d0)))))
    (loop (let ((result (run-loop mode s T)))
            (when (eql result :handled-source)
              (funcall function))
            (if (eql T timeout)
                (finish-output)
                (return))))))

(defmacro with-polling ((mode timeout) &body body)
  `(call-with-polling (lambda () ,@body) ,mode ,timeout))

(defun poll-devices (&key timeout)
  (with-polling (*run-loop-mode* timeout)))

(defun poll-events (device function &key timeout)
  (let ((*event-handler* function))
    (with-polling ((run-loop-mode device) timeout))))

;; (defun rumble (device &key)) ; TBD
