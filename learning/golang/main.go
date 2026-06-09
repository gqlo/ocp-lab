package main

import (
	"fmt"
	"log"
	"net/http"
	_ "net/http/pprof"
	"sync"
	"time"
)

func main() {
	go func() {
		log.Println(http.ListenAndServe("localhost:6060", nil))
	}()
	fmt.Println("hello world")

	var wg sync.WaitGroup
	wg.Add(1)
	go leakyFunction(&wg)
	wg.Wait()
}

func leakyFunction(wg *sync.WaitGroup) {
	defer wg.Done()
	s := make([]string, 3)
	for i := 0; i < 10_000_000; i++ {
		s = append(s, "magical pandas")
		if i%100_000 == 0 {
			time.Sleep(500 * time.Millisecond)
		}
	}
}
