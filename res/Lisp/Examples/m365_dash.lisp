;m365 dashboard free for all by Netzpfuscher
;red=5V black=GND yellow=COM-TX (UART-HDX) green=COM-RX (button)

;****User parameters****
;Calibrate throttle min max
(define cal-thr-lo 41.0)
(define cal-thr-hi 178.0)

;Calibrate brake min max
(define cal-brk-lo 40.0)
(define cal-brk-hi 178.0)

(define light-default 0)
(define show-faults 1)
(define show-batt-in-idle 1)

(define min-speed 1)

;****Code section****
(uart-start 115200 'half-duplex)
(gpio-configure 'pin-rx 'pin-mode-in-pu)

(define tx-frame (array-create 14))
(bufset-u16 tx-frame 0 0x55AA)
(bufset-u16 tx-frame 2 0x0821)
(bufset-u16 tx-frame 4 0x6400)

(define uart-buf (array-create type-byte 64))
(define throttle 0)
(define brake 0)
(define buttonold 0)
(define light 0)
(setvar 'light light-default)
(define c-out 0)
(define code 0)

(define presstime (systime))
(define presses 0)

(define off 0)
(define lock 0)
(define speedmode 1)

(defun inp (buffer) ;Frame 0x65
    (progn
    (setvar 'throttle (/(-(bufget-u8 uart-buf 4) cal-thr-lo) cal-thr-hi))
    (setvar 'brake (/(-(bufget-u8 uart-buf 5) cal-brk-lo) cal-brk-hi))
    
    ; todo: figure out how to calculate and set max rpm 
    (if (= speedmode 1) ; is drive?
        (print "drive")
        (if (= speedmode 2) ; is eco?
            (print "eco")
            (if (= speedmode 4) ; is sport?
                (print "sport"))))
    
    (if (= (+ off lock) 0)
        (progn
            (if (> (* (get-speed) 3.6) min-speed)
                (set-current-rel throttle)
                (set-current-rel 0))
                
            (if (> brake 0.02)
                (set-brake-rel brake))
        )
        (progn
            (set-current-rel 0)
            (if (= lock 1)
                (if (> (* (get-speed) 3.6) min-speed)
                    (set-brake-rel 1)
                    (set-brake-rel 0)
                )
                (set-brake-rel 0)
            )
        )
    )
    
    
))

(defun outp (buffer) ;Frame 0x64
    (progn
    (setvar 'crc 0)
    (looprange i 2 12
        (setvar 'crc (+ crc (bufget-u8 tx-frame i))))
    (setvar 'c-out (bitwise-xor crc 0xFFFF)) 
    (bufset-u8 tx-frame 12 c-out)
    (bufset-u8 tx-frame 13 (shr c-out 8))
    (uart-write tx-frame)
))

(defun read-thd ()
    (loopwhile t
        (progn
            (uart-read-bytes uart-buf 3 0)
            (if (= (bufget-u16 uart-buf 0) 0x55aa)
                (progn
                    (setvar 'len (bufget-u8 uart-buf 2))
                    (setvar 'crc len)
                    (if (> len 0) 
                        (progn
                            (uart-read-bytes uart-buf (+ len 4) 0)
                            (looprange i 0 len
                                (setvar 'crc (+ crc (bufget-u8 uart-buf i))))
                            (if (=(+(shl(bufget-u8 uart-buf (+ len 2))8) (bufget-u8 uart-buf (+ len 1))) (bitwise-xor crc 0xFFFF))
                                (progn
                                    (setvar 'code (bufget-u8 uart-buf 1))
                                    
                                    (if(= code 0x65)
                                        (inp uart-buf)
                                    )
                                    ;(if(= code 0x64)
                                        (outp uart-buf)
                                    ;)
                                )
                            )
                         )
                     )
)))))

(spawn 150 read-thd) ; Run UART in its own thread

(loopwhile t
    (progn
        (if (> buttonold (gpio-read 'pin-rx))
            (progn
                (setvar 'presses (+ presses 1))
                (setvar 'presstime (systime))
            )
            (if (> (- (systime) presstime) 4000) ;; double press
                (progn
                    (print presses)
                    (if (= presses 1)
                        (setvar 'light (bitwise-xor light 1))
                    )
                    
                    (if (>= presses 2) ; double press
                        (progn
                            ;; seems not to be working hmm
                            ;; (case speedmode
                            ;; (1 (setvar 'speedmode 4))
                            ;; (2 (setvar 'speedmode 1))
                            ;; (4 (setvar 'speedmode 2)))
                            
                            (if (> brake 0.02)
                                (setvar 'lock (bitwise-xor lock 1))
                                (if (= speedmode 1) ; is drive?
                                    (setvar 'speedmode 4) ; to sport
                                    (if (= speedmode 2) ; is eco?
                                        (setvar 'speedmode 1) ; to drive
                                        (if (= speedmode 4) ; is sport?
                                            (setvar 'speedmode 2)))) ; to eco
                            )
                        )
                    )
                
                    (setvar 'presses 0)
                )
            )
        )
        (setvar 'buttonold (gpio-read 'pin-rx))
        
        (if (= (gpio-read 'pin-rx) 0)
            (if (> (- (systime) presstime) 10000) ; long press
                (progn 
                    (setvar 'off (bitwise-xor off 1))
                    (setvar 'presstime (systime))
                )
            )
        )

        ; mode field (1=drive, 2=eco, 4=sport, 8=charge, 16=off, 32=lock)
        (if (= off 1)
            (bufset-u8 tx-frame 6 16) ; turn off display
            (if (= lock 1)
                (bufset-u8 tx-frame 6 32) ; lock display
                (bufset-u8 tx-frame 6 speedmode)
            )
        )
        
        ; batt field
        (bufset-u8 tx-frame 7 (*(get-batt) 100))
        ; light field
        (if (= off 0)
            (bufset-u8 tx-frame 8 light)
            (bufset-u8 tx-frame 8 0)
        )

        ; todo: add beeping on lock when pushing scooter

        ; speed field
        (if (= show-batt-in-idle 1)
            (if (> (* (get-speed) 3.6) 1)
                (bufset-u8 tx-frame 10 (* (get-speed) 3.6))
                (bufset-u8 tx-frame 10 (*(get-batt) 100)))
            (bufset-u8 tx-frame 10 (* (get-speed) 3.6))
        )
        
        (if (= show-faults 1)
            (bufset-u8 tx-frame 11 (get-fault))
        )
        (sleep 0.1)
))-