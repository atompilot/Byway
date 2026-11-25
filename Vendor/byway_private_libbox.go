package libbox

import (
	"context"
	"errors"
	"time"
)

type bywayPrivateEndpoint interface {
	BywayPrivateStatus(context.Context) ([]byte, error)
	BywayPrivateAction(context.Context, string, string) ([]byte, error)
}

func (s *CommandServer) bywayPrivate() bywayPrivateEndpoint {
	instance := s.Instance()
	if instance == nil || instance.Box() == nil {
		return nil
	}
	endpoint, _ := instance.Box().Endpoint().Get("byway-private")
	provider, _ := endpoint.(bywayPrivateEndpoint)
	return provider
}

func (s *CommandServer) BywayPrivateStatus() (string, error) {
	provider := s.bywayPrivate()
	if provider == nil {
		return "", errors.New("private network is not running")
	}
	ctx, cancel := context.WithTimeout(s.ctx, 2*time.Second)
	defer cancel()
	data, err := provider.BywayPrivateStatus(ctx)
	return string(data), err
}

func (s *CommandServer) BywayPrivateAction(action, value string) (string, error) {
	provider := s.bywayPrivate()
	if provider == nil {
		return "", errors.New("private network is not running")
	}
	ctx, cancel := context.WithTimeout(s.ctx, 7*time.Second)
	defer cancel()
	data, err := provider.BywayPrivateAction(ctx, action, value)
	return string(data), err
}
